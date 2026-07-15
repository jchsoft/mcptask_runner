# frozen_string_literal: true

require 'mcptask_runner/services/concerns/mcptask_piece_rest'

module McptaskRunner
  # CLI-driven bug reporter (type-1): prompts developer for title/description,
  # creates a bug piece on mcptask.online, and attaches the most recent run log
  # plus relevant config files.
  #
  # Bugs are routed into a dedicated Epic when config/mcptask_runner.yml has a
  # bug_destination: section — keeps auto-detected failures out of the
  # regular backlog. Env override: MCPTASK_BUG_PARENT_ID (relative_id of the
  # destination Epic) wins over the file, matching the "explicit beats config"
  # pattern of the other MCPTASK_*_ID env vars.
  #
  # Runner self-failures (type-2) are handled automatically by RunnerErrorReporter,
  # NOT here — those always land in the fixed "Errors" Epic, not bug_destination.
  #
  # Usage: rake mcptask_runner:bug_report
  class BugReporter
    include Concerns::McptaskPieceRest

    # Preserve the historical constant name so `BugReporter::Error` keeps resolving.
    Error = Concerns::McptaskPieceRest::Error
    BUG_PARENT_ENV = 'MCPTASK_BUG_PARENT_ID'.freeze

    def self.call
      new.call
    end

    def call
      raise Error, "real mcptask.online HTTP disabled via #{EventStream::DISABLE_ENV}" if real_http_disabled?

      check_config

      title = prompt('Bug title: ')
      description = collect_description

      puts '[BugReporter] Creating bug piece...'
      piece_id = create_piece(title, description)
      puts "[BugReporter] Created piece ##{piece_id}"

      attach_run_log(piece_id)
      attach_env_configs(piece_id)

      puts "[BugReporter] Done. Piece ##{piece_id} at: #{base_url}/#{account_code}/pieces/#{piece_id}"
    rescue Error => e
      warn "[BugReporter] Error: #{e.message}"
      raise
    end

    private

    def check_config
      raise Error, token_error if token.to_s.empty?
      raise Error, base_url_error if base_url.to_s.empty?
    end

    def token_error
      'MCPTASK token not configured (check .mcp.json or MCPTASK_TOKEN env var)'
    end

    def base_url_error
      'mcptask.online base URL not found (check .mcp.json or MCPTASK_BASE_URL env var)'
    end

    def prompt(message)
      $stdout.print(message)
      $stdout.flush
      $stdin.gets&.chomp.to_s
    end

    def collect_description
      puts 'Description (blank line to finish):'
      lines = []
      loop do
        line = $stdin.gets&.chomp
        break if line.nil? || line.empty?

        lines << line
      end
      lines.join("\n")
    end

    def create_piece(title, description)
      attrs = {
        name: title,
        description: description,
        piece_type: 'Task',
        task_type_code: 'bug',
        priority_code: 'high',
        project_id: project_id
      }
      parent = bug_parent_id
      attrs[:parent_id] = parent if parent
      post_piece(attrs)
    end

    # Returns Integer relative_id of the Epic that should hold this bug, or nil to
    # create at the project root. Priority: MCPTASK_BUG_PARENT_ID env > config/mcptask_runner.yml (bug_destination:) > nil.
    def bug_parent_id
      env_value = ENV[BUG_PARENT_ENV].to_s
      return env_value.to_i if env_value.match?(/\A\d+\z/) && env_value.to_i.positive?

      cfg = load_bug_destination_config
      cfg[:epic_relative_id] if cfg[:epic_relative_id].is_a?(Integer) && cfg[:epic_relative_id].positive?
    end

    def load_bug_destination_config
      require 'mcptask_runner/services/concerns/bug_destination_config'
      Concerns::BugDestinationConfig.load
    end

    def attach_run_log(piece_id)
      log_path = McptaskRunner::Logger.latest_run_log
      unless log_path
        puts '[BugReporter] No run log found, skipping'
        return
      end

      puts "[BugReporter] Attaching run log: #{log_path}"
      attach_content(piece_id, File.basename(log_path), File.read(log_path))
    end

    def attach_env_configs(piece_id)
      Concerns::McptaskPieceRest::ENV_CONFIGS.each do |relative_path|
        full_path = File.join(Dir.pwd, relative_path)
        next unless File.exist?(full_path)

        puts "[BugReporter] Attaching config: #{relative_path}"
        attach_content(piece_id, File.basename(relative_path), redact_tokens(File.read(full_path)))
      end
    end
  end
end
