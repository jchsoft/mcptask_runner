# frozen_string_literal: true

require 'English'

module McptaskRunner
  module Concerns
    # Handles triage-based model selection and task execution dispatch
    # Includes story detection, executor mapping, and branch-based task ID detection
    module TriageExecution
      STORY_EXECUTOR_MAP = {
        ClaudeCode::Honest => ClaudeCode::StoryManual,
        ClaudeCode::TodayAutoSquash => ClaudeCode::StoryAutoSquash,
        ClaudeCode::OnceAutoSquash => ClaudeCode::StoryAutoSquash,
        ClaudeCode::QueueAutoSquash => ClaudeCode::StoryAutoSquash
      }.freeze

      private

      def triage_and_execute(executor_class, **kwargs)
        task_id_for_triage = kwargs[:task_id] || @task_id || detect_task_id_from_branch
        story_id_for_triage = kwargs[:story_id]

        Logger.info_stdout('[WorkLoop] Running triage to select optimal model...')
        @builder&.set_task(task_id: task_id_for_triage)
        @builder&.set_status(:triage)
        EventStream.emit_snapshot(@builder.to_h, force: true) if @builder
        triage_result = ClaudeCode::Triage.new(verbose: @verbose, task_id: task_id_for_triage, story_id: story_id_for_triage, ignore_quota: @ignore_quota, snapshot_builder: @builder).run

        return triage_result if triage_result['status'] == 'no_more_tasks'

        if !@ignore_quota && triage_result['status'] == 'quota_exceeded'
          Logger.info_stdout('[WorkLoop] Triage reported quota exceeded')
          return { 'status' => 'quota_exceeded' }
        end

        if !@ignore_quota && triage_quota_exceeded?(triage_result)
          Logger.info_stdout('[WorkLoop] Quota already exceeded before execution, skipping task')
          return { 'status' => 'quota_exceeded' }
        end

        model_override = extract_triage_model(triage_result)
        triaged_task_id = resolve_triaged_task_id(triage_result, kwargs[:task_id])
        return { 'status' => 'error', 'message' => 'Triage completed but no task_id returned' } unless triaged_task_id

        resuming = triage_result['resuming'] == true
        model_override = upgrade_model_for_resume(model_override, resuming)
        Logger.info_stdout("[WorkLoop] Triage recommended model: #{model_override} (task_id: #{triaged_task_id}, resuming: #{resuming})")
        @builder&.set_model(model_override)
        @builder&.set_task(task_id: triaged_task_id, task_name: triage_result['task_name'])
        @builder&.set_status(:processing)
        EventStream.emit_snapshot(@builder.to_h, force: true) if @builder

        # Story detected from @next — switch to story loop
        if triage_result['piece_type'] == 'Story' && !kwargs[:story_id]
          story_id = triage_result['story_id']
          Logger.info_stdout("[WorkLoop] Story ##{story_id} detected from @next, switching to story loop")
          return run_story_loop(story_id, executor_class, model_override: model_override,
                                first_task_id: triaged_task_id, triage_result: triage_result)
        end

        execute_with_triage(executor_class, triaged_task_id, model_override, resuming,
                            triage_result: triage_result, **kwargs)
      end

      def execute_with_triage(executor_class, task_id, model_override, resuming, **kwargs)
        triage_result = kwargs.delete(:triage_result)
        executor_kwargs = kwargs.merge(verbose: @verbose, model_override: model_override, resuming: resuming, task_id: task_id, snapshot_builder: @builder)

        result = run_with_quota_guard(executor_class.new(**executor_kwargs), triage_result, task_id)
        Logger.info_stdout("[WorkLoop] Task completed with status: #{result['status']}")
        Logger.debug("[WorkLoop] Full result: #{result.inspect}")
        result
      end

      def run_with_quota_guard(executor, triage_result, task_id)
        apply_quota_watch(executor, triage_result) unless @ignore_quota
        switch_to_main_if_urgent_bug(executor.run)
      rescue McptaskRunner::QuotaExceededMidTaskError => e
        Logger.warn("[WorkLoop] #{e.message} — ending loop with quota_exceeded_mid_task")
        { 'status' => 'quota_exceeded_mid_task', 'task_id' => task_id }
      end

      # Safety net: when child Claude returns urgent_bug_pending while still on a feature branch,
      # the next triage's branch detection would re-pick the interrupted task instead of the urgent bug.
      # Switch to main so triage falls through to TaskDiscovery (or @next-based queue) and picks the bug.
      # If checkout fails (uncommitted changes), reclassify status so the loop aborts cleanly.
      def switch_to_main_if_urgent_bug(result)
        return result unless result.is_a?(Hash) && result['status'] == 'urgent_bug_pending'

        branch = current_git_branch
        return result if branch.empty? || %w[main master].include?(branch)

        Logger.info_stdout("[WorkLoop] Urgent bug ##{result['bug_task_id']} pending — switching from '#{branch}' to main")
        success, output = checkout_main_branch
        if success
          Logger.info_stdout('[WorkLoop] On main; next triage will pick urgent bug')
          return result
        end

        Logger.error("[WorkLoop] git checkout main failed (uncommitted changes on '#{branch}'?): #{output}")
        Logger.error('[WorkLoop] Setting status=urgent_bug_pending_dirty_branch — manual cleanup required')
        result['status'] = 'urgent_bug_pending_dirty_branch'
        result['dirty_branch'] = branch
        result
      end

      def current_git_branch
        `git branch --show-current 2>/dev/null`.strip
      end

      def checkout_main_branch
        output = `git checkout main 2>&1`
        [$CHILD_STATUS.success?, output.strip]
      end

      def apply_quota_watch(executor, triage_result)
        executor.quota_watch = build_quota_watch(triage_result)
      rescue NoMethodError
        # Executor doesn't support quota_watch (test mocks, future executors) — skip silently.
      end

      def build_quota_watch(triage_result)
        hours = triage_result&.dig('hours')
        return nil unless hours

        per_day = hours['per_day'].to_f
        return nil unless per_day.positive?

        { per_day_hours: per_day, already_worked_hours: hours['already_worked'].to_f }
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

      def extract_triage_model(triage_result)
        recommended = triage_result['recommended_model']
        case recommended
        when 'sonnet', 'opus', 'haiku' then recommended
        else
          Logger.warn("[WorkLoop] Unknown triage model '#{recommended}', defaulting to opus")
          'opus'
        end
      end

      # Resuming = previous attempt did not finish (context overflow, quota cutoff, urgent_bug interrupt).
      # Force opus on resume so a stronger model gets a shot at closing the task.
      def upgrade_model_for_resume(model, resuming)
        return model unless resuming
        return model if model == 'opus'

        Logger.info_stdout("[WorkLoop] Resuming task — upgrading model from '#{model}' to 'opus' (previous attempt likely couldn't finish)")
        'opus'
      end

      def story_executor_for(executor_class)
        STORY_EXECUTOR_MAP.fetch(executor_class) do
          Logger.warn("[WorkLoop] No story executor mapping for #{executor_class.name}, using StoryManual")
          ClaudeCode::StoryManual
        end
      end

      def detect_task_id_from_branch
        branch = `git branch --show-current 2>/dev/null`.strip
        return nil if branch.empty? || branch == 'main' || branch == 'master'

        match = branch.match(/(\d{4,})/)
        return nil unless match

        task_id = match[1].to_i
        Logger.info_stdout("[WorkLoop] Detected task ID #{task_id} from branch '#{branch}'")
        task_id
      end

      def triage_quota_exceeded?(triage_result)
        hours = triage_result['hours']
        return false unless hours

        raw_per_day = hours['per_day']
        if raw_per_day.nil?
          Logger.warn('[WorkLoop] Triage returned per_day=nil — mcptask://user read failed; skipping quota check')
          return false
        end

        per_day = raw_per_day.to_f
        if per_day.zero?
          Logger.info_stdout('[WorkLoop] per_day=0 (holiday or 0-hour day); treating quota as exceeded')
          return true
        end

        already_worked = hours['already_worked'].to_f
        exceeded = already_worked >= per_day
        Logger.debug("[WorkLoop] [triage_quota_exceeded?] per_day: #{per_day}h, already_worked: #{already_worked}h, exceeded: #{exceeded}")
        exceeded
      end
    end
  end
end
