# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Per-host config for the CLI tool the runner spawns.
    #
    # By default the runner drives the `claude` CLI, but any model-agnostic
    # coding CLI (Codex, Aider, Gemini CLI, OpenCode, …) can be driven instead
    # by pointing `launcher.command` at it and re-defining the flag names it
    # expects under `launcher.flags`. Same meaning, different spelling.
    #
    # Reads from the unified `config/mcptask_runner.yml`, under `launcher:`:
    #
    #   launcher:
    #     command: [aider]
    #     flags:
    #       prompt: "--message"        # rename a value flag
    #       model: "--model"
    #       output_format: null        # omit a flag the tool lacks
    #       verbose: null
    #       permission_mode: "--yes-always"
    #       disallowed_tools: null
    #
    # Flag semantics:
    #   * value flags (prompt, model, max_turns) emit `<flag> <value>`. Set the
    #     flag to null to pass the value positionally (`codex "do X"`), a real
    #     use case for tools that take the prompt as a bare argument.
    #   * standalone flags (continue, output_format, verbose, permission_mode)
    #     emit a single literal token, or nothing when set to null.
    #   * disallowed_tools appends its array (or single token) verbatim, or
    #     nothing when null.
    #
    # Omitting the `flags:` key (or any single key) keeps the claude defaults,
    # so an unconfigured host and a claude-only host behave identically.
    module LauncherConfig
      # Logical runner parameter => literal token(s) the claude CLI expects.
      DEFAULT_FLAGS = {
        'continue' => '--continue',
        'prompt' => '-p',
        'model' => '--model',
        'output_format' => '--output-format=stream-json',
        'verbose' => '--verbose',
        'max_turns' => '--max-turns',
        'permission_mode' => '--permission-mode=bypassPermissions',
        'disallowed_tools' => ['--disallowedTools', 'EnterPlanMode,ExitPlanMode']
      }.freeze

      module_function

      # The launch-command prefix array (replaces the autodetected claude path),
      # or nil when unconfigured.
      def command
        cmd = raw['command']
        cmd.freeze if cmd.is_a?(Array)
      end

      # Flag map with host overrides merged over the claude defaults. A key set
      # to null in the config survives the merge as nil, which the command
      # builder reads as "omit this flag".
      def flags
        overrides = raw['flags']
        overrides.is_a?(Hash) ? DEFAULT_FLAGS.merge(overrides) : DEFAULT_FLAGS
      end

      # True when the host redefined any flag — used for the boot banner.
      def flags_overridden?
        raw['flags'].is_a?(Hash) && !raw['flags'].empty?
      end

      def raw
        require_relative 'mcptask_runner_config'
        launcher = McptaskRunnerConfig.load['launcher']
        launcher.is_a?(Hash) ? launcher : {}
      rescue StandardError
        {}
      end
    end
  end
end
