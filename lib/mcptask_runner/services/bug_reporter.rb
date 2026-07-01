# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'base64'

module McptaskRunner
  # CLI-driven bug reporter: prompts developer for title/description,
  # creates a bug piece on mcptask.online, and attaches the most recent run log
  # plus relevant config files.
  #
  # Bugs are routed into a dedicated Epic when config/mcptask_runner.yml has a
  # bug_destination: section — keeps auto-detected failures out of the
  # regular backlog. Env override: MCPTASK_BUG_PARENT_ID (relative_id of the
  # destination Epic) wins over the file, matching the "explicit beats config"
  # pattern of the other MCPTASK_*_ID env vars.
  #
  # Usage: rake mcptask_runner:bug_report
  class BugReporter
    MCP_SERVER_KEY = 'mcptask-online'
    DEFAULT_ACCOUNT = 'jchsoft'
    DEFAULT_PROJECT_ID = 69
    HTTP_TIMEOUT = 30
    ENV_CONFIGS = %w[.mcp.json .claude/settings.json .claude/settings.local.json].freeze
    BUG_PARENT_ENV = 'MCPTASK_BUG_PARENT_ID'.freeze

    Error = Class.new(StandardError)

    def self.call
      new.call
    end

    def call
      raise Error, "real mcptask.online HTTP disabled via #{EventStream::DISABLE_ENV}" unless ENV[EventStream::DISABLE_ENV].to_s.empty?

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
      piece_attrs = {
        name: title,
        description: description,
        piece_type: 'Task',
        task_type_code: 'bug',
        priority_code: 'high',
        project_id: project_id
      }
      parent = bug_parent_id
      piece_attrs[:parent_id] = parent if parent

      body = JSON.generate({ piece: piece_attrs })
      response = http_post("/api/#{account_code}/pieces", body, 'Content-Type' => 'application/json')
      raise Error, "HTTP #{response.code} creating piece" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      data.dig('piece', 'relative_id') or raise Error, "no 'piece.relative_id' in create response"
    rescue JSON::ParserError => e
      raise Error, "invalid JSON from create piece: #{e.message}"
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
      ENV_CONFIGS.each do |relative_path|
        full_path = File.join(Dir.pwd, relative_path)
        next unless File.exist?(full_path)

        puts "[BugReporter] Attaching config: #{relative_path}"
        attach_content(piece_id, File.basename(relative_path), redact_tokens(File.read(full_path)))
      end
    end

    def attach_content(piece_id, file_name, content)
      body = JSON.generate({ attachment: { file_name: file_name, file_content: Base64.strict_encode64(content) } })
      response = http_post("/api/#{account_code}/pieces/#{piece_id}/attachments", body, 'Content-Type' => 'application/json')
      raise Error, "HTTP #{response.code} attaching #{file_name}" unless response.is_a?(Net::HTTPSuccess)
    end

    def redact_tokens(content)
      content
        .gsub(/"Bearer\s+[^"]{8,}"/, '"Bearer [REDACTED]"')
        .gsub(/("Authorization"\s*:\s*)"[^"]{8,}"/, '\1"[REDACTED]"')
    end

    def http_post(path, body, extra_headers = {})
      uri = URI.join(base_url, path)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https',
                      open_timeout: HTTP_TIMEOUT,
                      read_timeout: HTTP_TIMEOUT) do |http|
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{token}"
        request['Accept'] = 'application/json'
        extra_headers.each { |k, v| request[k] = v }
        request.body = body
        http.request(request)
      end
    end

    def token
      @token ||= resolve_token
    end

    def resolve_token
      env_name = token_env_name
      val = ENV.fetch(env_name, '')
      return val unless val.empty?

      auth = mcp_server_config&.dig('headers', 'Authorization').to_s
      match = auth.match(/\ABearer\s+(\S+)\z/)
      match ? match[1] : ''
    end

    def token_env_name
      auth = mcp_server_config&.dig('headers', 'Authorization').to_s
      match = auth.match(/\$\{(\w+)\}/)
      match ? match[1] : 'MCPTASK_TOKEN'
    end

    def base_url
      @base_url ||= ENV['MCPTASK_BASE_URL'].to_s.empty? ? base_url_from_mcp_json.to_s : ENV.fetch('MCPTASK_BASE_URL')
    end

    def base_url_from_mcp_json
      raw = mcp_server_config&.dig('url').to_s
      raw.sub(%r{/mcp/sse\z}, '')
    end

    def account_code
      ENV['MCPTASK_ACCOUNT'].to_s.empty? ? DEFAULT_ACCOUNT : ENV.fetch('MCPTASK_ACCOUNT')
    end

    def project_id
      ENV['MCPTASK_PROJECT_ID'].to_s.empty? ? DEFAULT_PROJECT_ID : ENV.fetch('MCPTASK_PROJECT_ID').to_i
    end

    def mcp_server_config
      mcp_json&.dig('mcpServers', MCP_SERVER_KEY)
    end

    def mcp_json
      @mcp_json ||= load_mcp_json
    end

    def load_mcp_json
      path = File.join(Dir.pwd, '.mcp.json')
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end
  end
end
