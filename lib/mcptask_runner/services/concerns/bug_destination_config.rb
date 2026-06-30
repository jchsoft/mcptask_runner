# frozen_string_literal: true

require 'yaml'

module McptaskRunner
  module Concerns
    # Per-host config for where bug pieces should land on mcptask.online.
    #
    # The runner (and BugReporter CLI) both create bug pieces. Without an explicit
    # destination they go to the project root, which fills up with "Fix: Padající
    # testy - …" tasks that compete with the user's actual backlog. Loading this
    # config lets us route every bug into a dedicated Epic — Epics have no
    # capacity limit, so the runner can pile failures there indefinitely without
    # starving the regular task queue.
    #
    # File format (config/bug_destination.yml, gitignored per-host):
    #   epic_relative_id: 12345   # Epic piece relative_id in the same account
    #   epic_name: "Auto-bugs"    # optional human label, surfaced in logs
    #
    # Resolved relative to Dir.pwd so the same code path works both inside the
    # gem's own test suite (Dir.pwd = the repo) and inside a host Rails project
    # (Dir.pwd = the project root).
    module BugDestinationConfig
      # Filename only — the directory is resolved at call time via Dir.pwd so
      # tests can chdir into a tmpdir without redefining a frozen constant.
      FILE_NAME = 'config/bug_destination.yml'.freeze

      module_function

      # Returns a Hash with :epic_relative_id (Integer or nil) and :epic_name (String or nil).
      # Never raises — a missing/invalid file is treated as "no config", same as
      # config/models.yml and config/launcher.yml. Callers branch on the nil case.
      def load
        path = file_path
        return missing unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        raw_id = data['epic_relative_id']
        epic_relative_id = raw_id.is_a?(Integer) ? raw_id : raw_id.to_s.match?(/\A\d+\z/) ? raw_id.to_i : nil
        epic_name = data['epic_name'].is_a?(String) ? data['epic_name'].strip : nil
        epic_name = nil if epic_name&.empty?
        { epic_relative_id: epic_relative_id, epic_name: epic_name }
      rescue StandardError
        missing
      end

      def file_path
        File.join(Dir.pwd, FILE_NAME)
      end

      def missing
        { epic_relative_id: nil, epic_name: nil }
      end

      # One-line human summary for the boot banner / log lines.
      # nil values render as "none" so the caller never has to nil-check.
      def describe
        cfg = load
        if cfg[:epic_relative_id].nil?
          'Bug destination: project root (no config/bug_destination.yml)'
        else
          name = cfg[:epic_name] ? " (#{cfg[:epic_name]})" : ''
          "Bug destination: Epic ##{cfg[:epic_relative_id]}#{name}"
        end
      end
    end
  end
end
