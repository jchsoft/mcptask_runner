# frozen_string_literal: true

require_relative 'next_task_auto_squash'

module McptaskRunner
  module ClaudeCode
    # Processes a single task with automatic PR squash-merge after CI passes
    # Unlike queue_auto_squash, this runs exactly once and exits
    class OnceAutoSquash < NextTaskAutoSquash
      private

      def task_description = "Next task, auto-merge after CI. ONCE mode — one task, then exit."
      def workflow_notice = "ONCE AUTO-SQUASH: one task, auto-merge after CI. CI fails 2× → PR stays open."
    end
  end
end
