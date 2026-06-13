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

      def task_description
        "Work on task ##{@task_id} from Story ##{@story_id} with AUTOMATIC PR merge after CI passes."
      end

      # Story discovery occupies steps 1-2, the git step is 3, so implementation starts at 4.
      def workflow_preamble
        "#{story_task_discovery_steps(story_id: @story_id, task_id: @task_id, skip_story_load: @skip_story_load)}\n\n" \
          "3. GIT: git checkout main && git pull"
      end

      def impl_start = 4

      def result_json_fields
        %("status": "success", "pr_number": N, "branch_name": "...", "story_id": #{@story_id}, "task_id": Z)
      end

      def status_block
        "task_id: relative_id of the task you worked on\n" \
          "#{auto_squash_status_options(no_more_tasks: 'no incomplete tasks in the Story', loop_note: true)}"
      end
    end
  end
end
