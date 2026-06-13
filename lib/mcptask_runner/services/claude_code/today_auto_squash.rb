# frozen_string_literal: true

require_relative 'next_task_auto_squash'

module McptaskRunner
  module ClaudeCode
    # Processes tasks from @next queue with automatic PR squash-merge after CI passes
    # Similar to run_today but with automatic merge instead of leaving PR open
    class TodayAutoSquash < NextTaskAutoSquash
      private

      def task_description = "Next task, auto-merge after CI."
      def workflow_notice = "AUTO-SQUASH: auto-merge after CI. CI fails 2× → PR stays open."
    end
  end
end
