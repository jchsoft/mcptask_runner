# frozen_string_literal: true

require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Processes a specific task by ID without auto-merge
    # Creates PR but leaves it open for human review
    class TaskManual < ClaudeCodeBase
      include WorkflowSteps

      def initialize(task_id:, verbose: false, model_override: nil, resuming: false, snapshot_builder: nil)
        super(verbose: verbose, model_override: model_override, resuming: resuming, snapshot_builder: snapshot_builder)
        @task_id = task_id
      end

      def model_name = "genius"
      def max_turns = 250

      private

      def build_instructions
        <<~INSTRUCTIONS
          #{persona_instruction}

          [TASK]
          Work on the specific task ##{@task_id}.

          #{context_optimization_instruction}

          #{time_awareness_instruction}

          #{coding_conventions_instruction}

          WORKFLOW:
          #{triaged_git_step(resuming: @resuming)}

          #{load_task_step(step_num: 2, task_id: @task_id)}

          #{create_branch_step(step_num: 3)}

          #{implement_task_step(step_num: 4)}

          #{run_unit_tests_step(step_num: 5)}

          #{prepare_screenshots_step(step_num: 6)}

          #{run_system_tests_step(step_num: 7)}

          #{refactor_step(step_num: 8)}

          #{verify_tests_step(step_num: 9)}

          #{push_step(step_num: 10)}

          #{create_pr_step(step_num: 11, no_merge_warning: true)}

          #{add_screenshots_to_pr_step(step_num: 12)}

          #{run_local_ci_step(step_num: 13, verify_step_ref: 9)}

          MANUAL workflow — PR created, NOT merged. Human reviews.

          #{result_format_instruction(
            %("status": "success", "hours": {"per_day": X, "task_estimated": Y, "already_worked": Z}, "task_id": #{@task_id})
          )}

          #{hours_data_instruction}
          3. Set status:
             - "success" if task completed successfully (PR created, NOT merged)
             #{urgent_bug_pending_status_option}
             - "failure" for other errors
        INSTRUCTIONS
      end
    end
  end
end
