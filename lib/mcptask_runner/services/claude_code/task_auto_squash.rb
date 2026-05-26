# frozen_string_literal: true

require_relative 'auto_squash_base'

module McptaskRunner
  module ClaudeCode
    # Processes a specific task by ID with automatic PR squash-merge after CI passes
    class TaskAutoSquash < AutoSquashBase
      def initialize(task_id:, verbose: false, model_override: nil, resuming: false, snapshot_builder: nil)
        super(verbose: verbose, model_override: model_override, resuming: resuming, snapshot_builder: snapshot_builder)
        @task_id = task_id
      end

      def model_name = "genius"

      private

      def build_instructions
        <<~INSTRUCTIONS
          #{persona_instruction}

          [TASK]
          Work on the specific task ##{@task_id} with AUTOMATIC PR merge after CI passes.

          WORKFLOW:
          #{triaged_git_step(resuming: @resuming)}

          #{load_task_step(step_num: 2, task_id: @task_id)}

          #{implementation_steps(start: 3)}
          #{ci_run_and_merge_step(step_num: 13, next_step: 14)}
          14. FINAL OUTPUT: Generate the result JSON

          AUTO-SQUASH: PR auto-merged after CI. CI fails 2× → PR stays open.

          #{result_format_instruction(
            %("status": "success", "pr_number": N, "branch_name": "...", "hours": {"per_day": X, "task_estimated": Y, "already_worked": Z}, "task_id": #{@task_id}),
            extra_rules: ['pr_number + branch_name REQUIRED whenever PR was created (success / ci_failed / merge_failed / preexisting_test_errors)']
          )}

          #{auto_squash_hours_data_instruction}
          3. Set status:
             - "success" if task completed AND `gh pr view <pr_number> --json state --jq .state` returns `MERGED`
             - "ci_failed" if CI failed after retry (PR stays open)
             - "merge_failed" if `gh pr merge` itself errored (branch protection, conflicts, etc.)
             - "preexisting_test_errors" if tests were already failing before your changes (urgent bug task created)
             - "already_done" if task already resolved (no code changes needed — e.g. fixed in earlier commit);
                 MUST log final progress at 100% naming the resolving commit SHA
             #{urgent_bug_pending_status_option}
             - "failure" for other errors
        INSTRUCTIONS
      end
    end
  end
end
