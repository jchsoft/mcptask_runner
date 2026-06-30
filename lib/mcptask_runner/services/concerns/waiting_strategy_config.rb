# frozen_string_literal: true

require 'yaml'

module McptaskRunner
  module Concerns
    # Per-host config for WaitingStrategy wait durations.
    #
    # When `config/waiting_strategy.yml` is missing, WaitingStrategy falls back
    # to the original hard-coded defaults (30 min short wait / 60 min long wait).
    # When the file is present, every key overrides a specific duration so
    # operators can shorten idle waits without touching source code.
    #
    # File format (config/waiting_strategy.yml, gitignored per-host):
    #   short_wait_minutes: 5
    #   long_wait_minutes: 30
    #
    # Resolved relative to Dir.pwd so the same code path works both inside the
    # gem's own test suite (Dir.pwd = the repo) and inside a host Rails project
    # (Dir.pwd = the project root). Mirrors BugDestinationConfig / launcher.yml
    # / models.yml conventions.
    module WaitingStrategyConfig
      # Filename only — the directory is resolved at call time via Dir.pwd so
      # tests can chdir into a tmpdir without redefining a frozen constant.
      FILE_NAME = 'config/waiting_strategy.yml'.freeze

      # Hard-coded fallback durations. short_wait is the "no tasks in
      # today_auto_squash" retry loop; long_wait is the "no tasks in daily"
      # retry loop. next_business_day_8am is computed, not configurable here.
      DEFAULT_SHORT_WAIT_MINUTES = 30
      DEFAULT_LONG_WAIT_MINUTES = 60

      module_function

      # Returns a Hash with :short_wait_minutes and :long_wait_minutes
      # (both Integer, in minutes). Never raises — a missing/invalid file
      # is treated as "no config" and the defaults are returned.
      def load
        path = file_path
        return defaults unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        {
          short_wait_minutes: parse_minutes(data['short_wait_minutes'], DEFAULT_SHORT_WAIT_MINUTES),
          long_wait_minutes: parse_minutes(data['long_wait_minutes'], DEFAULT_LONG_WAIT_MINUTES)
        }
      rescue StandardError
        defaults
      end

      def file_path
        File.join(Dir.pwd, FILE_NAME)
      end

      def defaults
        { short_wait_minutes: DEFAULT_SHORT_WAIT_MINUTES, long_wait_minutes: DEFAULT_LONG_WAIT_MINUTES }
      end

      # One-line human summary for the boot banner / log lines.
      # nil values render as "default" so the caller never has to nil-check.
      def describe
        cfg = load
        "Waiting strategy: short_wait=#{cfg[:short_wait_minutes]}m, long_wait=#{cfg[:long_wait_minutes]}m"
      end

      # Coerce raw YAML value to a positive integer (minutes). Non-positive or
      # non-numeric values fall back to the supplied default so a typo can't
      # produce a 0-second or negative wait.
      def parse_minutes(raw, default)
        return default if raw.nil?

        Integer(raw, exception: false).then { |n| n&.positive? ? n : default }
      end
    end
  end
end
