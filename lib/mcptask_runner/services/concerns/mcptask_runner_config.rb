# frozen_string_literal: true

require 'yaml'

module McptaskRunner
  module Concerns
    # Per-host unified config for the mcptask_runner gem.
    #
    # One file, one place — a single source of truth for models, launcher,
    # bug destination, and waiting strategy. Layout:
    #
    #   models:
    #     genius: claude-opus-4-8
    #     smart: claude-sonnet-4-6
    #     primitive: claude-haiku-4-5-20251001
    #   launcher:
    #     command: [ollama, launch, claude]
    #   bug_destination:
    #     epic_relative_id: 12345
    #     epic_name: Auto-bugs
    #   waiting_strategy:
    #     short_wait_minutes: 5
    #     long_wait_minutes: 30
    #
    # Resolved relative to Dir.pwd so the same code path works both inside the
    # gem's own test suite (Dir.pwd = the repo) and inside a host Rails project
    # (Dir.pwd = the project root).
    module McptaskRunnerConfig
      FILE_NAME = 'config/mcptask_runner.yml'.freeze

      module_function

      # Returns a Hash with optional :models, :launcher, :bug_destination, :waiting_strategy
      # keys (each a Hash). Missing/empty file => {}. Never raises — a malformed file
      # is treated as "no config" and the empty hash is returned.
      def load
        path = file_path
        return {} unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end

      def file_path
        File.join(Dir.pwd, FILE_NAME)
      end

      def exist?
        File.exist?(file_path)
      end
    end
  end
end
