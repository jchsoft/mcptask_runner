# frozen_string_literal: true

require 'yaml'

module McptaskRunner
  module Concerns
    # Per-host unified config for the mcptask_runner gem.
    #
    # One file, one place — operators no longer juggle 4 sibling files
    # (config/models.yml, config/launcher.yml, config/bug_destination.yml,
    # config/waiting_strategy.yml). Layout:
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
    # (Dir.pwd = the project root). Mirrors the old per-file loaders' convention.
    #
    # Backward compat: when the legacy per-file is present (config/models.yml,
    # etc.) AND the unified file is absent, the legacy file is used. This lets
    # hosts migrate at their own pace without a one-shot migration step. The
    # Installer writes the unified file in the recommended location; delete the
    # legacy files to switch sources.
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
