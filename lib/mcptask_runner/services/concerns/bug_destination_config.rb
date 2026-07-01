# frozen_string_literal: true

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
    # Reads from the unified `config/mcptask_runner.yml`, under the
    # `bug_destination:` key. When absent, callers fall back to project-root
    # placement.
    #
    # Unified format (config/mcptask_runner.yml):
    #   bug_destination:
    #     epic_relative_id: 12345   # Epic piece relative_id in the same account
    #     epic_name: "Auto-bugs"    # optional human label, surfaced in logs
    #
    # Resolved relative to Dir.pwd so the same code path works both inside the
    # gem's own test suite (Dir.pwd = the repo) and inside a host Rails project
    # (Dir.pwd = the project root).
    module BugDestinationConfig
      module_function

      # Returns a Hash with :epic_relative_id (Integer or nil) and :epic_name (String or nil).
      # Never raises — a missing/invalid file is treated as "no config", same as
      # the model and launcher configs. Callers branch on the nil case.
      def load
        data = load_raw
        raw_id = data['epic_relative_id']
        epic_relative_id = raw_id.is_a?(Integer) ? raw_id : raw_id.to_s.match?(/\A\d+\z/) ? raw_id.to_i : nil
        epic_name = data['epic_name'].is_a?(String) ? data['epic_name'].strip : nil
        epic_name = nil if epic_name&.empty?
        { epic_relative_id: epic_relative_id, epic_name: epic_name }
      rescue StandardError
        missing
      end

      def missing
        { epic_relative_id: nil, epic_name: nil }
      end

      # One-line human summary for the boot banner / log lines.
      # nil values render as "none" so the caller never has to nil-check.
      def describe
        cfg = load
        if cfg[:epic_relative_id].nil?
          'Bug destination: project root (no bug destination configured)'
        else
          name = cfg[:epic_name] ? " (#{cfg[:epic_name]})" : ''
          "Bug destination: Epic ##{cfg[:epic_relative_id]}#{name}"
        end
      end

      # Reads the bug_destination section of the unified config. Returns {} when
      # absent or empty — keeps `load` above free of duplicate fallback logic.
      def load_raw
        require_relative 'mcptask_runner_config'
        unified = McptaskRunnerConfig.load
        bd = unified['bug_destination']
        bd.is_a?(Hash) && !bd.empty? ? bd : {}
      end
    end
  end
end
