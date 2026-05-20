# frozen_string_literal: true

require "json"
require "uri"
require "securerandom"

module McptaskRunner
  # Streams runner events to mcptask.online via ActionCable WebSocket.
  # Cable URL and token auto-resolved from project's .mcp.json (mcptask-online server).
  # Disabled when no token is available.
  module EventStream
    CHANNEL_IDENTIFIER = JSON.generate({ channel: "RunnerSessionChannel" })
    MCP_SERVER_KEY = "mcptask-online"
    RECONNECT_THROTTLE_S = 30
    SNAPSHOT_THROTTLE_S = 0.5

    class << self
      def start_session(mode:)
        log_startup_diagnostics(mode: mode)
        unless enabled?
          Logger.info_stdout "[EventStream] DISABLED — #{disabled_reason}; runner snapshots will NOT reach mcptask.online"
          return
        end

        @subscribed = false
        @failed = false
        @error_logged = false
        @mutex = Mutex.new
        @subscribed_cv = ConditionVariable.new
        @session_id = SecureRandom.uuid
        @machine_id = ENV.fetch("HOSTNAME") { `hostname`.strip }
        @last_reconnect_attempt = nil
        @last_snapshot_emit = nil
        @last_snapshot = nil
        @last_emitted_status = nil
        @builder = SnapshotBuilder.new(session_id: @session_id, machine_id: @machine_id)

        Logger.info_stdout "[EventStream] Starting session: session_id=#{@session_id} machine_id=#{@machine_id.inspect} mode=#{mode.inspect}"
        connect
        Logger.info_stdout "[EventStream] Session ready: subscribed=#{@subscribed} failed=#{@failed} ws_open=#{@ws&.open?}"
      rescue StandardError => e
        Logger.warn "[EventStream] Failed to start session: #{e.class}: #{e.message}"
        Logger.warn "[EventStream]   backtrace: #{e.backtrace&.first(5)&.join(' | ')}"
      end

      def builder
        @builder
      end

      def emit_snapshot(snapshot_hash, force: false)
        return unless enabled?

        ws = @mutex&.synchronize { @ws }
        unless ws&.open?
          attempt_async_reconnect
          return
        end

        new_status = (snapshot_hash[:status] || snapshot_hash["status"])&.to_s
        is_closed = new_status == "closed"
        status_changed = new_status && new_status != @last_emitted_status

        unless force || is_closed || status_changed
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          last = @last_snapshot_emit
          return if last && (now - last) < SNAPSHOT_THROTTLE_S
        end

        @last_snapshot_emit = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_emitted_status = new_status if new_status
        @last_snapshot = snapshot_hash

        ws.send(JSON.generate({
          command: "message",
          identifier: CHANNEL_IDENTIFIER,
          data: JSON.generate({
            action: "snapshot",
            session_id: @session_id,
            machine_id: @machine_id,
            snapshot: snapshot_hash
          })
        }))
      rescue StandardError => e
        Logger.warn "[EventStream] Failed to emit snapshot: #{e.message}"
        attempt_async_reconnect
      end

      def end_session
        return unless enabled?

        @mutex&.synchronize do
          @ws&.close
          @ws = nil
          @session_id = nil
        end
      rescue StandardError => e
        Logger.warn "[EventStream] Failed to end session: #{e.message}"
      end

      def enabled?
        !resolved_token.to_s.empty? && !resolved_cable_url.to_s.empty?
      end

      private

      def log_startup_diagnostics(mode:)
        token = resolved_token.to_s
        Logger.info_stdout "[EventStream] === startup diagnostics (mode=#{mode.inspect}) ==="
        Logger.info_stdout "[EventStream]   pid=#{Process.pid} pwd=#{Dir.pwd}"
        Logger.info_stdout "[EventStream]   .mcp.json present? #{File.exist?(File.join(Dir.pwd, '.mcp.json'))}"
        Logger.info_stdout "[EventStream]   mcp_server_config present? #{!mcp_server_config.nil?}"
        Logger.info_stdout "[EventStream]   token_source=#{resolved_token_source} token_present? #{!token.empty?} (len=#{token.length})"
        Logger.info_stdout "[EventStream]   resolved_cable_url=#{resolved_cable_url.inspect}"
        Logger.info_stdout "[EventStream]   MCPT_RUNNER_CABLE_URL env=#{ENV['MCPT_RUNNER_CABLE_URL'].inspect}"
        Logger.info_stdout "[EventStream]   HOSTNAME env=#{ENV['HOSTNAME'].inspect} hostname()=#{`hostname`.strip.inspect}"
      rescue StandardError => e
        Logger.warn "[EventStream] startup diagnostics threw #{e.class}: #{e.message}"
      end

      def disabled_reason
        reasons = []
        reasons << "token unresolved (#{resolved_token_source} empty)" if resolved_token.to_s.empty?
        reasons << "cable URL unresolved (.mcp.json missing mcptask-online server entry?)" if resolved_cable_url.to_s.empty?
        reasons.join(", ")
      end

      def attempt_async_reconnect
        return unless @mutex && @session_id
        return if Thread.current[:eventstream_reconnecting]

        should_attempt = @mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          next false if @last_reconnect_attempt && now - @last_reconnect_attempt < RECONNECT_THROTTLE_S

          @last_reconnect_attempt = now
          true
        end

        return unless should_attempt

        Thread.new do
          Thread.current[:eventstream_reconnecting] = true
          Logger.info_stdout "[EventStream] WebSocket closed, attempting reconnect..."
          @mutex.synchronize do
            @subscribed = false
            @error_logged = false
            @failed = false
          end
          connect
        rescue StandardError => e
          Logger.warn "[EventStream] Reconnect failed: #{e.message}"
        end
      end

      def connect
        require "websocket-client-simple"

        url = cable_url
        Logger.info_stdout "[EventStream] Connecting to ActionCable url=#{url.sub(/token=[^&]+/, 'token=***')}"

        stream = self
        client = WebSocket::Client::Simple.connect(url, headers: handshake_headers) do |c|
          c.on(:open) do
            Logger.info_stdout "[EventStream] WebSocket open, sending subscribe (session_id=#{stream.instance_variable_get(:@session_id)})"
            c.send(JSON.generate({ command: "subscribe", identifier: CHANNEL_IDENTIFIER }))
          end

          c.on(:message) { |msg| stream.send(:handle_message, msg.data) }

          c.on(:error) { |e| stream.send(:handle_error, c, e) }

          c.on(:close) { Logger.info_stdout "[EventStream] WebSocket closed (session_id=#{stream.instance_variable_get(:@session_id)})" }
        end

        @mutex.synchronize { @ws = client }
        wait_for_subscription
      end

      def handle_error(client, error)
        should_log = @mutex.synchronize do
          break false if @error_logged

          @error_logged = true
          @failed = true
          @subscribed_cv.signal
          true
        end
        Logger.warn "[EventStream] WebSocket error: #{error.message} — disabling stream" if should_log
        client.close
      rescue StandardError
        nil
      end

      def handshake_headers
        origin = origin_from_cable_url
        origin ? { "Origin" => origin } : {}
      end

      def origin_from_cable_url
        uri = URI.parse(resolved_cable_url)
        scheme = uri.scheme == "wss" ? "https" : "http"
        return nil if uri.host.nil?

        "#{scheme}://#{uri.host}"
      rescue URI::InvalidURIError
        nil
      end

      def handle_message(data)
        return if data.nil? || data.empty?

        parsed = JSON.parse(data)
        return unless parsed["type"] == "confirm_subscription"

        Logger.info_stdout "[EventStream] Subscription confirmed (session_id=#{@session_id})"
        @mutex.synchronize do
          @subscribed = true
          @subscribed_cv.signal
        end

        emit_snapshot(@last_snapshot, force: true) if @last_snapshot
      rescue JSON::ParserError
        nil
      rescue StandardError => e
        Logger.warn "[EventStream] Error handling message: #{e.message}"
      end

      def wait_for_subscription(timeout: 10)
        @mutex.synchronize do
          @subscribed_cv.wait(@mutex, timeout) unless @subscribed || @failed
        end
        Logger.warn "[EventStream] Subscription timed out" unless @subscribed || @failed
      end

      def cable_url
        "#{resolved_cable_url.delete_suffix('/')}?token=#{resolved_token}"
      end

      def resolved_cable_url
        ENV["MCPT_RUNNER_CABLE_URL"].to_s.empty? ? cable_url_from_mcp_json : ENV.fetch("MCPT_RUNNER_CABLE_URL")
      end

      def resolved_token
        auth = mcp_server_config&.dig("headers", "Authorization").to_s
        if (match = auth.match(/\$\{(\w+)\}/))
          ENV.fetch(match[1], "")
        elsif (match = auth.match(/\ABearer\s+(\S+)\z/))
          match[1]
        else
          ENV.fetch("MCPTASK_TOKEN", "")
        end
      end

      def resolved_token_source
        auth = mcp_server_config&.dig("headers", "Authorization").to_s
        if (match = auth.match(/\$\{(\w+)\}/))
          "ENV[#{match[1].inspect}]"
        elsif auth.match(/\ABearer\s+\S+\z/)
          ".mcp.json Authorization (literal)"
        else
          "ENV[\"MCPTASK_TOKEN\"] (fallback)"
        end
      end

      def cable_url_from_mcp_json
        mcp_server_url&.sub(%r{\Ahttps://}, "wss://")&.sub(%r{/mcp/sse\z}, "/cable").to_s
      end

      def mcp_server_url
        mcp_server_config&.dig("url")
      end

      def mcp_server_config
        mcp_json&.dig("mcpServers", MCP_SERVER_KEY)
      end

      def mcp_json
        @mcp_json ||= load_mcp_json
      end

      def load_mcp_json
        path = File.join(Dir.pwd, ".mcp.json")
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end
    end
  end
end
