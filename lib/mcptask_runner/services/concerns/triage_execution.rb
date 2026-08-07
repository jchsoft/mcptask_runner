# frozen_string_literal: true

require 'English'
require_relative 'urgent_bug_pin'

module McptaskRunner
  module Concerns
    # Handles triage-based model selection and task execution dispatch
    # Includes story detection, executor mapping, and branch-based task ID detection
    module TriageExecution
      include UrgentBugPin

      # Statuses that mean child created an urgent bug + checked out main.
      # Both must pin so next triage targets the new bug instead of cycling on
      # mcptask @next, which still returns the interrupted task.
      URGENT_BUG_PIN_STATUSES = %w[urgent_bug_pending preexisting_test_errors].freeze

      # Literal sample title shipped in the triage prompt (task_base.rb / story.rb). Weak
      # models that skip the STEP 2 fetch echo it verbatim — never publish it as a real name.
      PLACEHOLDER_TASK_NAME = 'Piece title'

      # Shown on the web card while triage is still discovering which task to run. In @next
      # discovery mode there's no task_id yet, so without a name the snapshot frame carries
      # task_id:nil/task_name:nil and the dashboard has nothing to render until the
      # triage→processing handoff. A label gives the card something to show during triage.
      # Overwritten by the real task name at execute time (set_task in triage_and_execute).
      TRIAGE_TASK_PLACEHOLDER = 'Triaging next task…'

      STORY_EXECUTOR_MAP = {
        ClaudeCode::Honest => ClaudeCode::StoryManual,
        ClaudeCode::TodayAutoSquash => ClaudeCode::StoryAutoSquash,
        ClaudeCode::OnceAutoSquash => ClaudeCode::StoryAutoSquash,
        ClaudeCode::QueueAutoSquash => ClaudeCode::StoryAutoSquash
      }.freeze

      # Urgent pin bypasses triage entirely — pinned bug is a standalone Task, must be processed
      # directly with genius. Map every parent executor (story or @next-based) to the matching
      # Task executor so the bug never goes through Story/@next discovery.
      URGENT_BUG_EXECUTOR_MAP = {
        ClaudeCode::Honest => ClaudeCode::TaskManual,
        ClaudeCode::TodayAutoSquash => ClaudeCode::TaskAutoSquash,
        ClaudeCode::OnceAutoSquash => ClaudeCode::TaskAutoSquash,
        ClaudeCode::QueueAutoSquash => ClaudeCode::TaskAutoSquash,
        ClaudeCode::StoryManual => ClaudeCode::TaskManual,
        ClaudeCode::StoryAutoSquash => ClaudeCode::TaskAutoSquash
      }.freeze

      private

      def triage_and_execute(executor_class, **kwargs)
        pinned_id = read_urgent_pin
        task_id_for_triage = kwargs[:task_id] || @task_id
        return execute_pinned_urgent_bug(pinned_id, executor_class) if pinned_id && (task_id_for_triage.nil? || task_id_for_triage == pinned_id)

        story_id_for_triage = kwargs[:story_id]

        Logger.info_stdout('[WorkLoop] Running triage to select optimal model...')
        @builder&.set_task(task_id: task_id_for_triage, task_name: TRIAGE_TASK_PLACEHOLDER)
        @builder&.set_status(:triage)
        EventStream.emit_snapshot(@builder.to_h, force: true) if @builder
        triage_result = run_verified_triage(task_id: task_id_for_triage, story_id: story_id_for_triage)

        return triage_result if triage_result['status'] == 'no_more_tasks'

        if !@ignore_quota && QuotaGuard.exceeded?
          Logger.info_stdout('[WorkLoop] Quota exceeded before execution (live REST), skipping task')
          return { 'status' => 'quota_exceeded' }
        end

        model_override = extract_triage_model(triage_result)
        triaged_task_id = resolve_triaged_task_id(triage_result, kwargs[:task_id])
        return { 'status' => 'error', 'message' => 'Triage completed but no task_id returned' } unless triaged_task_id

        resuming = triage_result['resuming'] == true
        model_override = upgrade_model_for_resume(model_override, resuming)
        Logger.info_stdout("[WorkLoop] Triage recommended model: #{model_override} (task_id: #{triaged_task_id}, resuming: #{resuming})")
        @builder&.set_model(model_override)
        @builder&.set_task(task_id: triaged_task_id, task_name: resolve_task_name(triage_result, kwargs[:task_id]))
        @builder&.set_status(:processing)
        EventStream.emit_snapshot(@builder.to_h, force: true) if @builder

        # Story detected from @next — switch to story loop
        if triage_result['piece_type'] == 'Story' && !kwargs[:story_id]
          story_id = triage_result['story_id']
          Logger.info_stdout("[WorkLoop] Story ##{story_id} detected from @next, switching to story loop")
          return run_story_loop(story_id, executor_class, model_override: model_override,
                                first_task_id: triaged_task_id)
        end

        execute_with_triage(executor_class, triaged_task_id, model_override, resuming,
                            triage_result: triage_result, **kwargs)
      end

      # A weak model can emit a syntactically perfect TASKRUNNER_RESULT for a task it never fetched.
      # Seen on projectoid_ii / qwen3.5 on 2026-08-07: triage called NO tool at all (12 stream
      # events, one thinking line) and answered task_id 11360 paired with a task_name belonging to a
      # different piece in a different project — the runner then branched and started editing files
      # for that made-up pairing. The stream is the only proof of a real fetch (Triage stamps
      # 'fetch_observed'), so an unfetched pick is discarded and triage re-run in a fresh session.
      # Still unfetched → answer no_more_tasks: the waiting strategy re-triages in minutes, which is
      # strictly better than working an id nobody looked up. Only a pick triage INVENTED is checked;
      # a task_id we handed in (pinned bug, explicit --task) is trustworthy by construction.
      def run_verified_triage(task_id:, story_id:)
        2.times do |attempt|
          result = ClaudeCode::Triage.new(verbose: @verbose, task_id: task_id, story_id: story_id, snapshot_builder: @builder).run
          return result unless unverified_task_pick?(result, task_id)

          Logger.warn("[WorkLoop] Triage picked task ##{result['task_id']} (#{result['task_name'].inspect}) " \
                      "without fetching any piece — made-up pick, discarding (attempt #{attempt + 1}/2)")
        end

        { 'status' => 'no_more_tasks', 'reason' => 'triage_unverified' }
      end

      def unverified_task_pick?(result, supplied_task_id)
        return false unless result.is_a?(Hash) && result['fetch_observed'] == false

        picked = result['task_id']
        !picked.nil? && picked.to_s != supplied_task_id.to_s
      end

      # Bypass triage whenever an urgent pin is active. Pinned bug is hardcoded as the next
      # piece of work — runner must not consult triage (which could pick a different task or
      # re-pick the interrupted parent) and must not auto-resume from a sitting branch.
      def execute_pinned_urgent_bug(pinned_id, parent_executor_class)
        bug_executor_class = URGENT_BUG_EXECUTOR_MAP.fetch(parent_executor_class) do
          Logger.warn("[WorkLoop] No urgent-bug executor mapping for #{parent_executor_class.name}, using TaskAutoSquash")
          ClaudeCode::TaskAutoSquash
        end

        Logger.info_stdout("[WorkLoop] Urgent pin ##{pinned_id} active — bypassing triage, running #{bug_executor_class.name} with genius")
        @task_id = pinned_id
        @builder&.set_model('genius')
        @builder&.set_task(task_id: pinned_id, task_name: read_urgent_pin_name)
        @builder&.set_status(:processing)
        EventStream.emit_snapshot(@builder.to_h, force: true) if @builder

        executor = bug_executor_class.new(task_id: pinned_id, verbose: @verbose,
                                          model_override: 'genius', resuming: false,
                                          snapshot_builder: @builder)
        result = run_with_quota_guard(executor, pinned_id)
        Logger.info_stdout("[WorkLoop] Pinned urgent bug ##{pinned_id} completed with status: #{result['status']}")
        release_urgent_pin_if_done(pinned_id, result)
        result
      end

      def execute_with_triage(executor_class, task_id, model_override, resuming, **kwargs)
        kwargs.delete(:triage_result)
        executor_kwargs = kwargs.merge(verbose: @verbose, model_override: model_override, resuming: resuming, task_id: task_id, snapshot_builder: @builder)

        result = run_with_quota_guard(executor_class.new(**executor_kwargs), task_id)
        Logger.info_stdout("[WorkLoop] Task completed with status: #{result['status']}")
        Logger.debug("[WorkLoop] Full result: #{result.inspect}")
        release_urgent_pin_if_done(task_id, result)
        result
      end

      # Pinned bug finished its turn — clear pin so the next loop iteration goes back to
      # discovery (which naturally resumes the originally interrupted task via branch detection).
      # Cascading sub-bug case (result is another urgent_bug_pending) was already handled in
      # switch_to_main_if_urgent_bug, which overwrote the pin with the new bug_task_id.
      def release_urgent_pin_if_done(task_id, result)
        return unless result.is_a?(Hash)
        return if URGENT_BUG_PIN_STATUSES.include?(result['status'])
        return unless read_urgent_pin == task_id

        clear_urgent_pin
        @task_id = nil
      end

      def run_with_quota_guard(executor, task_id)
        apply_quota_watch(executor) unless @ignore_quota
        switch_to_main_if_urgent_bug(executor.run)
      rescue McptaskRunner::QuotaExceededMidTaskError => e
        Logger.warn("[WorkLoop] #{e.message} — ending loop with quota_exceeded_mid_task")
        { 'status' => 'quota_exceeded_mid_task', 'task_id' => task_id }
      end

      # Safety net: when child Claude returns urgent_bug_pending OR preexisting_test_errors while
      # still on a feature branch, the next triage's branch detection would re-pick the interrupted
      # task instead of the urgent bug. Switch to main so triage falls through to TaskDiscovery
      # (or @next-based queue) and picks the bug. If checkout fails (uncommitted changes),
      # reclassify status so the loop aborts cleanly.
      def switch_to_main_if_urgent_bug(result)
        return result unless result.is_a?(Hash) && URGENT_BUG_PIN_STATUSES.include?(result['status'])

        branch = current_git_branch
        if branch.empty? || %w[main master].include?(branch)
          pin_urgent_bug(result['bug_task_id'], result['bug_task_name'])
          return result
        end

        Logger.info_stdout("[WorkLoop] Urgent bug ##{result['bug_task_id']} pending — switching from '#{branch}' to main")
        success, output = checkout_main_branch
        if success
          pin_urgent_bug(result['bug_task_id'], result['bug_task_name'])
          return result
        end

        Logger.error("[WorkLoop] git checkout main failed (uncommitted changes on '#{branch}'?): #{output}")
        Logger.error('[WorkLoop] Setting status=urgent_bug_pending_dirty_branch — manual cleanup required')
        result['status'] = 'urgent_bug_pending_dirty_branch'
        result['dirty_branch'] = branch
        result
      end

      def pin_urgent_bug(bug_task_id, task_name = nil)
        unless bug_task_id
          Logger.warn('[WorkLoop] urgent_bug_pending without bug_task_id — cannot pin; next triage will fall back to discovery')
          return
        end

        bug_id = bug_task_id.to_i
        write_urgent_pin(bug_id, task_name)
        @task_id = bug_id
        Logger.info_stdout("[WorkLoop] Urgent pin set — next triage targets piece ##{bug_id}")
      end

      def current_git_branch
        `git branch --show-current 2>/dev/null`.strip
      end

      def checkout_main_branch
        output = `git checkout main 2>&1`
        [$CHILD_STATUS.success?, output.strip]
      end

      # Arm the executor's mid-task heartbeat guard with live quota numbers (REST, not
      # agent self-report). Seeds the UI badge; the heartbeat then re-polls REST itself.
      def apply_quota_watch(executor)
        status = QuotaGuard.status
        return unless status.rest_ok && status.per_day.positive?

        executor.quota_watch = { per_day_hours: status.per_day, already_worked_hours: status.worked_today }
      rescue NoMethodError
        # Executor doesn't support quota_watch (test mocks, future executors) — skip silently.
      end

      def resolve_triaged_task_id(triage_result, explicit_task_id)
        triaged_task_id = triage_result['task_id']

        unless triaged_task_id
          Logger.error('[WorkLoop] Triage did not return a task_id')
          return nil
        end

        if explicit_task_id && triaged_task_id != explicit_task_id
          Logger.warn("[WorkLoop] Triage returned task_id #{triaged_task_id} but explicit task_id #{explicit_task_id} was requested, using explicit")
          return explicit_task_id
        end

        triaged_task_id
      end

      # Triage's task_name is only trustworthy when it came from the piece triage actually
      # fetched. Drop it when the id was overridden (name belongs to a different/placeholder
      # context) or when it's blank / the literal prompt sample. nil → UI shows just the id.
      def resolve_task_name(triage_result, explicit_task_id)
        return nil if explicit_task_id && triage_result['task_id'] != explicit_task_id

        name = triage_result['task_name'].to_s.strip
        return nil if name.empty? || name == PLACEHOLDER_TASK_NAME

        name
      end

      def extract_triage_model(triage_result)
        recommended = triage_result['recommended_model']
        case recommended
        when 'smart', 'genius', 'primitive' then recommended
        else
          Logger.warn("[WorkLoop] Unknown triage model '#{recommended}', defaulting to genius")
          'genius'
        end
      end

      # Resuming = previous attempt did not finish (context overflow, quota cutoff, urgent_bug interrupt).
      # Force genius on resume so a stronger model gets a shot at closing the task.
      def upgrade_model_for_resume(model, resuming)
        return model unless resuming
        return model if model == 'genius'

        Logger.info_stdout("[WorkLoop] Resuming task — upgrading model from '#{model}' to 'genius' (previous attempt likely couldn't finish)")
        'genius'
      end

      def story_executor_for(executor_class)
        STORY_EXECUTOR_MAP.fetch(executor_class) do
          Logger.warn("[WorkLoop] No story executor mapping for #{executor_class.name}, using StoryManual")
          ClaudeCode::StoryManual
        end
      end
    end
  end
end
