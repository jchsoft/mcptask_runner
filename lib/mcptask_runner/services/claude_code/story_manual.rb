# frozen_string_literal: true

require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Processes tasks from a specific Story without auto-merge
    # Creates PRs for each task but leaves them open for human review
    class StoryManual < ClaudeCodeBase
      include WorkflowSteps

      def initialize(story_id:, task_id:, skip_story_load: false, **options)
        super(**options)
        @story_id = story_id
        @task_id = task_id
        @skip_story_load = skip_story_load
      end

      def model_name = "genius"
      def max_turns = 250

      private

      def build_instructions
        <<~INSTRUCTIONS
          [TASK]
          Work on task ##{@task_id} from Story ##{@story_id}.

          #{todo_list_instruction}

          #{context_optimization_instruction}

          #{time_awareness_instruction}

          WORKFLOW:
          #{story_task_discovery_steps(story_id: @story_id, task_id: @task_id, skip_story_load: @skip_story_load)}

          3. GIT: git checkout main && git pull

          #{create_branch_step(step_num: 4)}

          #{implement_task_step(step_num: 5)}

          #{run_unit_tests_step(step_num: 6)}

          #{prepare_screenshots_step(step_num: 7)}

          #{run_system_tests_step(step_num: 8)}

          #{verify_tests_step(step_num: 9)}

          #{push_step(step_num: 10)}

          #{create_pr_step(step_num: 11, no_merge_warning: true)}

          #{add_screenshots_to_pr_step(step_num: 12)}

          #{run_local_ci_step(step_num: 13, verify_step_ref: 9)}

          MANUAL: PR created, NOT merged. Human reviews.

          #{result_format_instruction(
            %("status": "success", "story_id": #{@story_id}, "task_id": Z)
          )}

          #{progress_logging_instruction}

          task_id: relative_id of the task you worked on
          Set status:
             - "success" if task completed successfully (PR created, NOT merged)
             - "no_more_tasks" if no incomplete tasks in the Story
             #{urgent_bug_pending_status_option}
             - "failure" for other errors
        INSTRUCTIONS
      end
    end
  end
end
