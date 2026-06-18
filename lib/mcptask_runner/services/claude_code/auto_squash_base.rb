# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Base class for auto-squash workflows.
    # Provides shared instruction fragments for the implementation and CI+merge steps
    # so they are defined in one place across today/once/queue/story variants.
    class AutoSquashBase < ClaudeCodeBase
      include WorkflowSteps

      def max_turns = 300

      # Pre-flight gate: if a merged PR already references @task_id, skip the
      # full implementation/CI/merge session and run a minimal Claude that only
      # logs 100% progress + emits already_done. Prevents wasting ~200K tokens
      # re-discovering a task that finished but whose previous run crashed
      # before logging final progress (the merge_unverified failure mode).
      def run
        preflight = preflight_merged_pr_match
        return run_fast_track_already_done(preflight) if preflight

        super
      end

      private

      def preflight_merged_pr_match
        return nil unless @task_id

        out, status = Open3.capture2('gh', 'pr', 'list',
                                     '--state', 'merged',
                                     '--search', @task_id.to_s,
                                     '--json', 'number,title,body,headRefName,mergeCommit',
                                     '--limit', '10')
        return nil unless status.success?

        prs = JSON.parse(out)
        match = prs.find { |pr| pr_matches_task?(pr, @task_id) } or return nil

        Logger.info_stdout("[#{@log_tag}] [preflight] Task ##{@task_id} found in merged PR ##{match['number']} — fast-track already_done")
        { pr_number: match['number'], merge_commit: match.dig('mergeCommit', 'oid').to_s }
      rescue JSON::ParserError, StandardError => e
        Logger.warn("[#{@log_tag}] [preflight] check failed (#{e.class}: #{e.message}) — proceeding with full execution")
        nil
      end

      # Override RetryHandling default: when context overflows on auto-squash, the merge
      # may already have happened (gh pr merge → main update → final LogWorkProgressTool)
      # before some post-merge skill bloated the session. Treat that as success instead of
      # error; the work is irreversibly merged and the effort is logged.
      def handle_context_overflow(start_time)
        if @task_id && (merged = post_merge_state_for_task)
          elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)
          Logger.warn "[#{@log_tag}] Context overflow but PR ##{merged[:pr_number]} for task " \
                      "##{@task_id} is MERGED — inferring success (#{elapsed_hours}h)"
          return {
            'status' => 'success',
            'task_id' => @task_id,
            'pr_number' => merged[:pr_number],
            'merge_commit' => merged[:merge_commit],
            'inferred_from_merge' => true,
            'message' => "Context overflow after merge — recovered success from PR ##{merged[:pr_number]}",
            'hours' => { 'task_worked' => elapsed_hours }
          }
        end

        super
      end

      def post_merge_state_for_task
        preflight_merged_pr_match&.then { |m| { pr_number: m[:pr_number], merge_commit: m[:merge_commit] } }
      end

      # Match a PR to a task_id via: title word-match, body containing the
      # mcptask URI, or branch name with the id as a path/segment.
      def pr_matches_task?(pr, task_id)
        id = task_id.to_s
        pattern_word = /(?<!\d)#{id}(?!\d)/
        return true if pr['title'].to_s.match?(pattern_word)
        return true if pr['body'].to_s.include?("pieces/#{account_code}/#{id}")

        pr['headRefName'].to_s.match?(%r{(?:^|[/-])#{id}(?:-|$)})
      end

      # Build the minimal fast-track instruction (no implementation, no CI,
      # no merge) and execute it. Uses a singleton-method override so we
      # don't need a separate executor class or a flag in subclass dispatch.
      def run_fast_track_already_done(preflight)
        ensure_on_main_branch
        define_singleton_method(:build_instructions) { fast_track_already_done_instructions(preflight) }
        Logger.info_stdout("[#{@log_tag}] Starting FAST-TRACK already_done (PR ##{preflight[:pr_number]} already merged)")
        @accumulated_output = ''.dup
        @text_content = ''.dup
        run_with_retry(Time.now)
      end

      def ensure_on_main_branch
        branch, status = Open3.capture2('git', 'branch', '--show-current')
        branch = branch.to_s.strip
        return if !status.success? || branch.empty? || %w[main master].include?(branch)

        Logger.info_stdout("[#{@log_tag}] [preflight] on '#{branch}' — switching to main")
        out, st = Open3.capture2e('git', 'checkout', 'main')
        if st.success?
          Open3.capture2e('git', 'pull')
        else
          Logger.warn("[#{@log_tag}] [preflight] git checkout main failed: #{out.strip}")
        end
      end

      def fast_track_already_done_instructions(preflight)
        pr_number = preflight[:pr_number]
        sha7 = preflight[:merge_commit][0, 7]
        commit_note = sha7.empty? ? '' : " (commit #{sha7})"

        <<~INSTRUCTIONS
          [FAST-TRACK already_done]
          Runner preflight found task ##{@task_id} already merged in PR ##{pr_number}#{commit_note}.

          DO NOT touch git. DO NOT run tests/CI. Only close the task in mcptask:

          1. Read mcptask://user (server="mcptask-online", LITERAL URI — no account suffix)
             → get current user relative_id
          2. LogWorkProgressTool:
             account_code="#{account_code}", piece_id=#{@task_id}, progress_percent=100,
             duration_minutes=1,
             description="Preflight: merged PR ##{pr_number}#{commit_note} already resolves this task"
          3. Output the final result line and STOP:

          TASKRUNNER_RESULT:
          {"status":"already_done","task_id":#{@task_id},"pr_number":#{pr_number},"preflight_skipped":true}
        INSTRUCTIONS
      end

      AUTO_SQUASH_NOTICE = 'AUTO-SQUASH: PR auto-merged after CI. CI fails 2× → PR stays open.'
      PR_FIELDS_RULE = 'pr_number + branch_name REQUIRED whenever PR was created ' \
                       '(success / ci_failed / merge_failed / preexisting_test_errors)'

      # Template shared by every auto-squash variant. Subclasses override only the small hooks
      # below (task_description / workflow_preamble / impl_start / workflow_notice /
      # result_json_fields / status_block); all structure lives here so the five variants stay
      # in lockstep.
      def build_instructions
        <<~INSTRUCTIONS
          [TASK]
          #{task_description}

          WORKFLOW:
          #{workflow_preamble}

          #{workflow_body(start: impl_start)}

          #{workflow_notice}

          #{result_format_instruction(result_json_fields, extra_rules: [PR_FIELDS_RULE])}

          #{auto_squash_progress_logging_instruction}

          #{status_block}
        INSTRUCTIONS
      end

      # On --continue retries we send only the short continuation prompt; re-state the exact
      # result-format contract (same one build_instructions emits) so the resumed session can't
      # forget the marker — the failure mode that triggers marker-retry in the first place.
      def continuation_result_contract
        result_format_instruction(result_json_fields, extra_rules: [PR_FIELDS_RULE])
      end

      # --- variant hooks (defaults here; subclasses override what differs) ---
      def impl_start = 3
      def workflow_notice = AUTO_SQUASH_NOTICE

      def task_description
        raise NotImplementedError, "#{self.class} must implement task_description"
      end

      def workflow_preamble
        raise NotImplementedError, "#{self.class} must implement workflow_preamble"
      end

      def result_json_fields
        raise NotImplementedError, "#{self.class} must implement result_json_fields"
      end

      def status_block
        raise NotImplementedError, "#{self.class} must implement status_block"
      end

      # Single source for the auto-squash status enum. `no_more_tasks` text varies per variant
      # (nil omits the line for fixed-task runners); `loop_note` appends the loop-continuation
      # hint to already_done for the queue/today/story loops.
      def auto_squash_status_options(no_more_tasks: nil, loop_note: false)
        loop_hint = loop_note ? ', so triage does not re-pick the same task; loop continues to next task' : ''
        lines = ['- "success" if task completed AND `gh pr view <pr_number> --json state --jq .state` returns `MERGED`']
        lines << %(- "no_more_tasks" if #{no_more_tasks}) if no_more_tasks
        lines << '- "ci_failed" if CI failed after retry (PR stays open)'
        lines << '- "merge_failed" if PR merge skill or `gh pr merge` itself errored (branch protection, conflicts, etc.)'
        lines << '- "preexisting_test_errors" if tests were already failing before your changes (urgent bug task created)'
        lines << '- "already_done" if task already resolved (no code changes needed — e.g. fixed in earlier commit / fix branch is empty); ' \
                 "MUST log final progress at 100% naming the resolving commit SHA#{loop_hint}"
        lines << urgent_bug_pending_status_option
        lines << '- "failure" for other errors'
        "Set status:\n#{lines.join("\n")}"
      end

      # Autosquash variant of progress_logging_instruction. Same milestones but 100% is gated
      # on an actual `gh pr view` merge check — prevents marking task done when PR was
      # never merged (preexisting tests, ci_failed, merge_failed).
      def auto_squash_progress_logging_instruction
        <<~INSTRUCTION.strip
          PROGRESS LOGGING (MANDATORY — min 3× LogWorkProgressTool calls during run):
          - Single 100% call at end = UNACCEPTABLE. Caller sees no interim state.
          - Milestones (minimum cadence, bump progress_percent each time):
            a) After branch created + task understood → ~20%
            b) After implementation + unit tests pass → ~60%
            c) ONLY after `gh pr view <pr_number> --json state --jq .state` returns `MERGED` → 100%
               UNMERGED outcomes (ci_failed / merge_failed / preexisting_test_errors / failure):
               cap at 80%. Description states non-merge reason. NEVER 100% for unmerged work.
               EXCEPTION — already_done: REQUIRED 100% (resolution exists in prior merged commit),
                 description names the resolving commit SHA so triage closes the task.
          - Each call: duration_minutes = minutes since previous call (not cumulative);
            description = what was done since last log.
          - More calls OK for long tasks; 3× is floor, not target.
        INSTRUCTION
      end

      # Runner-side merge verification. Called from ResultParsing#parse_result via the
      # `respond_to?(:post_parse_result, true)` hook. If Claude reported `success` but
      # `gh pr view --json state` says otherwise, reclassify to `merge_unverified` so
      # the loop breaks and decider does not count the task as completed.
      def post_parse_result(result)
        return result unless result['status'] == 'success'

        pr_number = result['pr_number'] || lookup_pr_number_from_branch(result['branch_name'])
        unless pr_number
          Logger.info_stdout("[#{@log_tag}] [merge_verify] WARN: status=success but pr_number missing and lookup failed → merge_unverified")
          result['status'] = 'merge_unverified'
          result['merge_verification_error'] = 'pr_number missing and gh pr list fallback found no PR'
          return result
        end

        state_str, status = Open3.capture2('gh', 'pr', 'view', pr_number.to_s, '--json', 'state', '--jq', '.state')
        merged = status.success? && state_str.strip == 'MERGED'

        if merged
          Logger.debug "[#{@log_tag}] [merge_verify] PR ##{pr_number} confirmed merged"
          return result
        end

        reason = status.success? ? "gh pr view returned state=#{state_str.strip.inspect}" : "gh pr view exited non-zero (#{status.exitstatus})"
        Logger.info_stdout("[#{@log_tag}] [merge_verify] WARN: status=success but PR ##{pr_number} not merged (#{reason}) → merge_unverified")
        result['status'] = 'merge_unverified'
        result['merge_verification_error'] = reason
        result
      end

      def lookup_pr_number_from_branch(branch_name)
        branch = branch_name || `git branch --show-current`.strip
        return nil if branch.empty? || branch == 'main' || branch == 'master'

        out, status = Open3.capture2('gh', 'pr', 'list', '--head', branch, '--state', 'all', '--json', 'number', '--jq', '.[0].number')
        return nil unless status.success?

        n = out.strip
        n.empty? ? nil : n.to_i
      end

      # Instruction blocks + numbered implementation steps + CI/merge + final-output line.
      # Step numbers derive from the step count, so adding/removing a step renumbers everything
      # downstream automatically. today/once/queue/task start at 3, story starts at 4.
      def workflow_body(start:)
        steps = [
          todo_list_instruction,
          context_optimization_instruction,
          time_awareness_instruction,
          preexisting_test_errors_instruction,
          create_branch_step(step_num: start),
          implement_task_step(step_num: start + 1),
          run_unit_tests_step(step_num: start + 2),
          compile_test_assets_step(step_num: start + 3),
          run_system_tests_step(step_num: start + 4),
          verify_tests_step(step_num: start + 5),
          push_step(step_num: start + 6),
          create_pr_step(step_num: start + 7, auto_merge_note: true),
          skip_screenshots_step(step_num: start + 8)
        ]
        ci_step = start + 9
        final_step = ci_step + 1
        <<~BODY.strip
          #{steps.reject(&:empty?).join("\n\n")}

          #{ci_run_and_merge_step(step_num: ci_step, next_step: final_step)}
          #{final_step}. FINAL OUTPUT: Generate the result JSON
        BODY
      end

      # Returns the full CI run-and-auto-merge step.
      # step_num: the step number shown to the agent (14 for today/once/queue, 15 for story)
      # next_step: the final output step number to skip to when bin/ci is absent
      def ci_run_and_merge_step(step_num:, next_step:)
        <<~STEP
          #{step_num}. CI + AUTO-MERGE:
              - No bin/ci → skip to step #{next_step}, status "success"
              - Invoke /ci-runner
              - NOTE: bin/ci posts "signoff" status to GitHub via gh. Satisfies branch protection.
                Disabled CI workflow (ci.yml.disabled) irrelevant — signoff is local. PR IS mergeable.
              - CI PASSES:
                → use skill to merge PR or: gh pr merge --squash --delete-branch
                → git checkout main && git pull
                → status "success"
              - CI FAILS:
                → Analyze, fix, commit, push
                → Retry bin/ci
                → Retry passes → merge (above)
                → Retry fails → status "ci_failed" (PR stays open)
        STEP
      end
    end
  end
end
