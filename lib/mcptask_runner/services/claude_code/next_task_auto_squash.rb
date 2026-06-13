# frozen_string_literal: true

require_relative 'auto_squash_base'

module McptaskRunner
  module ClaudeCode
    # Shared base for @next-queue auto-squash runners (today/once/queue). They differ only in
    # task_description + workflow_notice; all other hooks (preamble, json fields, status enum)
    # are identical and live here.
    class NextTaskAutoSquash < AutoSquashBase
      def initialize(verbose: false, model_override: nil, task_id: nil, resuming: false, snapshot_builder: nil)
        super(verbose: verbose, model_override: model_override, resuming: resuming, snapshot_builder: snapshot_builder)
        @task_id = task_id
      end

      def model_name = "genius"

      private

      def workflow_preamble
        "#{triaged_git_step(resuming: @resuming)}\n\n#{task_fetch_step(step_num: 2, fetch_url: task_fetch_url)}"
      end

      def result_json_fields = '"status": "success", "pr_number": N, "branch_name": "..."'

      def status_block
        auto_squash_status_options(
          no_more_tasks: 'no tasks available (mcptask returns "No available tasks found")',
          loop_note: true
        )
      end
    end
  end
end
