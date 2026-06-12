# frozen_string_literal: true

require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Executes real work - creates branches, modifies code, creates PRs
    class Honest < ClaudeCodeBase
      include WorkflowSteps

      def initialize(verbose: false, model_override: nil, task_id: nil, resuming: false, snapshot_builder: nil)
        super(verbose: verbose, model_override: model_override, resuming: resuming, snapshot_builder: snapshot_builder)
        @task_id = task_id
      end

      def model_name = "genius"
      def max_turns = 200

      private

      def build_instructions
        project_relative_id or raise 'project_relative_id not found in CLAUDE.md'
        fetch_url = task_fetch_url

        <<~INSTRUCTIONS
          #{persona_instruction}
          [TASK] Work on next task from: #{fetch_url}. Create PR, run CI. Follow ALL workflow steps.

          #{todo_list_instruction}

          #{context_optimization_instruction}

          #{time_awareness_instruction}

          #{coding_conventions_instruction}

          WORKFLOW:
          #{triaged_git_step(resuming: @resuming)}

          #{task_fetch_step(step_num: 2, fetch_url: fetch_url)}

          #{create_branch_step(step_num: 3)}

          #{implement_task_step(step_num: 4)}

          #{run_unit_tests_step(step_num: 5)}

          #{prepare_screenshots_step(step_num: 6, special_method_hint: true)}

          #{run_system_tests_step(step_num: 7)}

          #{refactor_step(step_num: 8)}

          #{verify_tests_step(step_num: 9)}

          #{push_step(step_num: 10, set_upstream: false)}

          #{create_pr_step(step_num: 11)}

          #{add_screenshots_to_pr_step(step_num: 12)}

          #{run_local_ci_step(step_num: 13, verify_step_ref: 9)}

          ⚠️ TASK IS NOT COMPLETE UNTIL LOCAL CI PASSES (step 13)

          #{result_format_instruction(
            '"status": "success"'
          )}

          #{progress_logging_instruction}

          Set status:
             - "success" if task completed successfully
             - "no_more_tasks" if no tasks available (mcptask returns "No available tasks found")
             #{urgent_bug_pending_status_option}
             - "failure" for other errors
        INSTRUCTIONS
      end
    end
  end
end
