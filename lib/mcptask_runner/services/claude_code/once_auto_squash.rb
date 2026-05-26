# frozen_string_literal: true

require_relative 'auto_squash_base'

module McptaskRunner
  module ClaudeCode
    # Processes a single task with automatic PR squash-merge after CI passes
    # Unlike queue_auto_squash, this runs exactly once and exits
    class OnceAutoSquash < AutoSquashBase
      def initialize(verbose: false, model_override: nil, task_id: nil, resuming: false, snapshot_builder: nil)
        super(verbose: verbose, model_override: model_override, resuming: resuming, snapshot_builder: snapshot_builder)
        @task_id = task_id
      end

      def model_name = "genius"

      private

      def build_instructions
        build_next_task_instructions(
          task_description: "Next task, auto-merge after CI. ONCE mode — one task, then exit.",
          workflow_notice: "ONCE AUTO-SQUASH: one task, auto-merge after CI. CI fails 2× → PR stays open."
        )
      end
    end
  end
end
