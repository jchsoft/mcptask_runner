# frozen_string_literal: true

require_relative 'next_task_auto_squash'

module McptaskRunner
  module ClaudeCode
    # Processes tasks from @next queue with automatic PR squash-merge after CI passes
    # Runs continuously 24/7 without quota checks or time limits
    class QueueAutoSquash < NextTaskAutoSquash
      private

      def task_description = "Next task, auto-merge after CI. QUEUE mode — 24/7, no quota checks."
      def workflow_notice = "QUEUE AUTO-SQUASH: 24/7, no quota. Auto-merge after CI. CI fails 2× → PR stays open, runner stops."
    end
  end
end
