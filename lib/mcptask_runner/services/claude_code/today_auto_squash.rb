# frozen_string_literal: true

require_relative 'auto_squash_base'

module McptaskRunner
  module ClaudeCode
    # Processes tasks from @next queue with automatic PR squash-merge after CI passes
    # Similar to run_today but with automatic merge instead of leaving PR open
    class TodayAutoSquash < AutoSquashBase
      def initialize(verbose: false, model_override: nil, task_id: nil, resuming: false, snapshot_builder: nil)
        super(verbose: verbose, model_override: model_override, resuming: resuming, snapshot_builder: snapshot_builder)
        @task_id = task_id
      end

      def model_name = "genius"

      private

      def build_instructions
        build_next_task_instructions(
          task_description: "Next task, auto-merge after CI.",
          workflow_notice: "AUTO-SQUASH: auto-merge after CI. CI fails 2× → PR stays open."
        )
      end
    end
  end
end
