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

      def task_description
        "Work on the specific task ##{@task_id} with AUTOMATIC PR merge after CI passes."
      end

      def workflow_preamble
        "#{triaged_git_step(resuming: @resuming)}\n\n#{load_task_step(step_num: 2, task_id: @task_id)}"
      end

      def result_json_fields
        %("status": "success", "pr_number": N, "branch_name": "...", "task_id": #{@task_id})
      end

      def status_block
        auto_squash_status_options(no_more_tasks: nil)
      end
    end
  end
end
