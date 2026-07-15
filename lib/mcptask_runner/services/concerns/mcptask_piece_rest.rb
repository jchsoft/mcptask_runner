# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'base64'

module McptaskRunner
  module Concerns
    # Shared REST plumbing for creating pieces + attaching files on mcptask.online.
    #
    # Extracted from BugReporter so both the interactive bug CLI (type-1: bugs the
    # child agent finds in the target project) and the automatic RunnerErrorReporter
    # (type-2: the runner itself crashing) share one HTTP client, one token/base-url
    # resolution, and one attachment/redaction path.
    #
    # The including class supplies the DESTINATION (account_code / project_id / parent)
    # by overriding the accessors below; this module only knows HOW to talk to the API.
    module McptaskPieceRest
      MCP_SERVER_KEY = 'mcptask-online'
      DEFAULT_ACCOUNT = 'jchsoft'
      DEFAULT_PROJECT_ID = 69
      HTTP_TIMEOUT = 30
      ENV_CONFIGS = %w[.mcp.json .claude/settings.json .claude/settings.local.json].freeze

      Error = Class.new(StandardError)

      private

      # POST a piece and return its Integer relative_id. attrs is the full piece body
      # (name / description / task_type_code / priority_code / project_id / parent_id …).
      def post_piece(attrs)
        response = http_post("/api/#{account_code}/pieces", JSON.generate({ piece: attrs }), 'Content-Type' => 'application/json')
        raise Error, "HTTP #{response.code} creating piece" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).dig('piece', 'relative_id') or raise Error, "no 'piece.relative_id' in create response"
      rescue JSON::ParserError => e
        raise Error, "invalid JSON from create piece: #{e.message}"
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

      def real_http_disabled?
        !ENV[EventStream::DISABLE_ENV].to_s.empty?
      end

      def token
        @token ||= resolve_token
      end

      def resolve_token
        val = ENV.fetch(token_env_name, '')
        return val unless val.empty?

        match = mcp_server_config&.dig('headers', 'Authorization').to_s.match(/\ABearer\s+(\S+)\z/)
        match ? match[1] : ''
      end

      def token_env_name
        match = mcp_server_config&.dig('headers', 'Authorization').to_s.match(/\$\{(\w+)\}/)
        match ? match[1] : 'MCPTASK_TOKEN'
      end

      def base_url
        @base_url ||= ENV['MCPTASK_BASE_URL'].to_s.empty? ? base_url_from_mcp_json.to_s : ENV.fetch('MCPTASK_BASE_URL')
      end

      def base_url_from_mcp_json
        mcp_server_config&.dig('url').to_s.sub(%r{/mcp/sse\z}, '')
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
end
