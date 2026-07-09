# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Per-host config for the pull-request template file path.
    #
    # The runner tells the AI agent which file to follow when creating a PR.
    # The default (`.github/pull_request_template.md`) works for GitHub-hosted
    # projects; GitLab users or repos with a different layout can override it
    # here without patching the gem.
    #
    # Reads from the unified `config/mcptask_runner.yml`, under the
    # `pr_template:` key:
    #
    #   pr_template:
    #     path: .gitlab/merge_request_templates/Default.md
    #
    # When absent, the default path is used.
    module PrTemplateConfig
      DEFAULT_PATH = '.github/pull_request_template.md'.freeze

      module_function

      # Returns a Hash with :path (String). Never raises — a missing/invalid
      # file is treated as "no config" and the default path is returned.
      def load
        data = load_raw
        raw_path = data['path']
        path = raw_path.is_a?(String) ? raw_path.strip : nil
        path = nil if path&.empty?
        { path: path || DEFAULT_PATH }
      rescue StandardError
        defaults
      end

      def defaults
        { path: DEFAULT_PATH }
      end

      def load_raw
        require_relative 'mcptask_runner_config'
        unified = McptaskRunnerConfig.load
        pt = unified['pr_template']
        pt.is_a?(Hash) && !pt.empty? ? pt : {}
      end

      private :load_raw
    end
  end
end
