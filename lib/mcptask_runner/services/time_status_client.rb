# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module McptaskRunner
  # Direct REST client for mcptask.online's authoritative quota source.
  #
  # Replaces the estimate-based Decider accounting that drifts when task_estimated
  # undershoots task_worked. Reads /api/{account}/users/current/time_status and
  # returns the same `worked_today` / `per_day` the UI shows.
  #
  # Token + base URL resolved from .mcp.json (same mechanism as EventStream) so
  # the runner stays portable across machines. Raises on any failure — callers
  # should rescue and fall back rather than swallow silently.
  class TimeStatusClient
    MCP_SERVER_KEY = 'mcptask-online'
    DEFAULT_ACCOUNT = 'jchsoft'
    HTTP_TIMEOUT = 10

    Error = Class.new(StandardError)

    class << self
      # Returns { worked_today: Float, per_day: Float } or raises Error.
      def fetch
        new.fetch
      end
    end

    def fetch
      raise Error, "real mcptask.online HTTP disabled via #{EventStream::DISABLE_ENV}" unless ENV[EventStream::DISABLE_ENV].to_s.empty?
      raise Error, 'MCPTASK token env var not set' if token.to_s.empty?
      raise Error, 'mcptask.online base URL not found in .mcp.json' if base_url.to_s.empty?

      response = http_get(endpoint_uri)
      raise Error, "HTTP #{response.code} from #{endpoint_uri}" unless response.is_a?(Net::HTTPSuccess)

      parse(response.body)
    end

    private

    def parse(body)
      data = JSON.parse(body)
      today = data['today'] or raise Error, "no 'today' key in response"

      { worked_today: today['value'].to_f, per_day: today['hour_goal'].to_f }
    rescue JSON::ParserError => e
      raise Error, "invalid JSON: #{e.message}"
    end

    def http_get(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = "Bearer #{token}"
        request['Accept'] = 'application/json'
        http.request(request)
      end
    end

    def endpoint_uri
      URI.join(base_url, "/api/#{account_code}/users/current/time_status")
    end

    def account_code
      ENV['MCPTASK_ACCOUNT'].to_s.empty? ? DEFAULT_ACCOUNT : ENV.fetch('MCPTASK_ACCOUNT')
    end

    def base_url
      @base_url ||= explicit_base_url || base_url_from_mcp_json
    end

    def explicit_base_url
      url = ENV['MCPTASK_BASE_URL'].to_s
      url.empty? ? nil : url
    end

    # Strip /mcp/sse suffix from MCP server URL to get the REST base.
    def base_url_from_mcp_json
      raw = mcp_server_config&.dig('url').to_s
      return nil if raw.empty?

      raw.sub(%r{/mcp/sse\z}, '')
    end

    def token
      @token ||= ENV.fetch(token_env_name, '')
    end

    def token_env_name
      return 'MCPTASK_TOKEN' unless mcp_server_config

      auth = mcp_server_config.dig('headers', 'Authorization').to_s
      match = auth.match(/\$\{(\w+)\}/)
      match ? match[1] : 'MCPTASK_TOKEN'
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
