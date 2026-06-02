# frozen_string_literal: true

require_relative 'auto_squash_base'

module McptaskRunner
  module ClaudeCode
    # Processes tasks from a specific Story with automatic PR squash-merge after CI passes
    # Creates PRs for each task and automatically merges them after local CI passes
    class StoryAutoSquash < AutoSquashBase
      def initialize(story_id:, task_id:, skip_story_load: false, **options)
        super(**options)
        @story_id = story_id
        @task_id = task_id
        @skip_story_load = skip_story_load
      end

      def model_name = "genius"

      private

      def build_instructions
        <<~INSTRUCTIONS
          #{persona_instruction}

          [TASK]
          Work on task ##{@task_id} from Story ##{@story_id} with AUTOMATIC PR merge after CI passes.

          WORKFLOW:
          #{story_task_discovery_steps(story_id: @story_id, task_id: @task_id, skip_story_load: @skip_story_load)}

          3. GIT: git checkout main && git pull

          #{implementation_steps(start: 4)}
          #{ci_run_and_merge_step(step_num: 14, next_step: 15)}
          15. FINAL OUTPUT: Generate the result JSON

          AUTO-SQUASH: PR auto-merged after CI. CI fails 2× → PR stays open.

          #{result_format_instruction(
            %("status": "success", "pr_number": N, "branch_name": "...", "story_id": #{@story_id}, "task_id": Z),
            extra_rules: ['pr_number + branch_name REQUIRED whenever PR was created (success / ci_failed / merge_failed / preexisting_test_errors)']
          )}

          #{auto_squash_progress_logging_instruction}

          task_id: relative_id of the task you worked on
          Set status:
             - "success" if task completed AND `gh pr view <pr_number> --json state --jq .state` returns `MERGED`
             - "no_more_tasks" if no incomplete tasks in the Story
             - "ci_failed" if CI failed after retry (PR stays open)
             - "merge_failed" if `gh pr merge` itself errored (branch protection, conflicts, etc.)
             - "preexisting_test_errors" if tests were already failing before your changes (urgent bug task created)
             - "already_done" if task already resolved (no code changes needed — e.g. fixed in earlier commit);
                 MUST log final progress at 100% naming the resolving commit SHA, so triage does not re-pick;
                 loop continues to next task
             #{urgent_bug_pending_status_option}
             - "failure" for other errors
        INSTRUCTIONS
      end
    end
  end
end
