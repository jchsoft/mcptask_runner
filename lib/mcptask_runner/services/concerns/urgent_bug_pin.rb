# frozen_string_literal: true

require 'fileutils'
require 'json'

module McptaskRunner
  module Concerns
    # Restart-safe pin for urgent bug task_id returned by child Claude
    # (status=urgent_bug_pending or status=preexisting_test_errors — both create urgent bugs).
    # Without it, mcptask.online @next keeps returning the interrupted task and the runner
    # cycles forever instead of switching to the newly created bug.
    #
    # Pin file format: plain "12345" (no name) or JSON {"id":"12345","name":"Fix: ..."} (with name).
    # Plain-text format is preserved for backward compatibility with existing pins.
    module UrgentBugPin
      private

      PIN_FILE = File.join('tmp', 'mcptask_runner', 'urgent_pin.txt').freeze

      def urgent_pin_path
        File.join(Dir.pwd, PIN_FILE)
      end

      def write_urgent_pin(task_id, task_name = nil)
        FileUtils.mkdir_p(File.dirname(urgent_pin_path))
        content = task_name.to_s.strip.empty? ? task_id.to_s : JSON.generate({ id: task_id.to_s, name: task_name })
        File.write(urgent_pin_path, content)
        Logger.info_stdout("[WorkLoop] Urgent pin written: piece ##{task_id} (#{urgent_pin_path})")
      end

      def read_urgent_pin
        return nil unless File.exist?(urgent_pin_path)

        pin_id(File.read(urgent_pin_path).strip).then { |n| n.positive? ? n : nil }
      end

      def read_urgent_pin_name
        return nil unless File.exist?(urgent_pin_path)

        pin_name(File.read(urgent_pin_path).strip)
      end

      def clear_urgent_pin
        return unless File.exist?(urgent_pin_path)

        File.delete(urgent_pin_path)
        Logger.info_stdout('[WorkLoop] Urgent pin cleared')
      end

      def pin_id(content)
        parsed = JSON.parse(content)
        parsed.is_a?(Hash) ? parsed['id'].to_i : parsed.to_i
      rescue JSON::ParserError
        content.to_i
      end

      def pin_name(content)
        parsed = JSON.parse(content)
        return nil unless parsed.is_a?(Hash)

        name = parsed['name'].to_s.strip
        name.empty? ? nil : name
      rescue JSON::ParserError
        nil
      end
    end
  end
end
