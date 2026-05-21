# frozen_string_literal: true

require 'fileutils'

module McptaskRunner
  module Concerns
    # Restart-safe pin for urgent bug task_id returned by child Claude (status=urgent_bug_pending).
    # Without it, mcptask.online @next keeps returning the interrupted task and the runner
    # cycles forever instead of switching to the newly created bug.
    module UrgentBugPin
      private

      PIN_FILE = File.join('tmp', 'mcptask_runner', 'urgent_pin.txt').freeze

      def urgent_pin_path
        File.join(Dir.pwd, PIN_FILE)
      end

      def write_urgent_pin(task_id)
        FileUtils.mkdir_p(File.dirname(urgent_pin_path))
        File.write(urgent_pin_path, task_id.to_s)
        Logger.info_stdout("[WorkLoop] Urgent pin written: piece ##{task_id} (#{urgent_pin_path})")
      end

      def read_urgent_pin
        return nil unless File.exist?(urgent_pin_path)

        File.read(urgent_pin_path).strip.to_i.then { |n| n.positive? ? n : nil }
      end

      def clear_urgent_pin
        return unless File.exist?(urgent_pin_path)

        File.delete(urgent_pin_path)
        Logger.info_stdout('[WorkLoop] Urgent pin cleared')
      end
    end
  end
end
