# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Handles real-time stream processing: stdout/stderr reading, tool tracking, result detection, debug dumps
    module StreamProcessing
      private

      def stream_lines(io)
        io.each_line do |line|
          yield line
          break if @state.result_received || @state.stopping
        end
      end

      def handle_stream_error(error, stream_name)
        return if @state.stopping # Expected closure during timeout/shutdown

        error_msg = "#{stream_name} stream closed unexpectedly: #{error.message}"
        Logger.warn "[#{@log_tag}] #{error_msg}"
        yield error_msg
      end

      # Claude Code's Skill tool (and other forked-execution tools) emit completion via
      # `type:system, subtype:task_notification, status:completed` rather than a standard
      # `tool_result` content item. Without this, the tool stays "active" in active_actions
      # forever — heartbeat hung-tool detection then false-positive kills legitimate ci-wait
      # polling loops. Match by tool_use_id and mark finished idempotently.
      def track_system_task_event(line)
        parsed = JSON.parse(line)
        return unless parsed['type'] == 'system' && parsed['subtype'] == 'task_notification'
        return unless %w[completed failed].include?(parsed['status'])

        tool_use_id = parsed['tool_use_id']
        return unless tool_use_id

        action = @snapshot_builder.active_actions_snapshot[tool_use_id]
        return unless action

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration = (now - action[:mono_started_at]).round(1)
        @snapshot_builder.tool_finished(tool_id: tool_use_id)
        EventStream.emit_snapshot(@snapshot_builder.to_h)
        Logger.debug "[#{@log_tag}] [tool_tracking] Tool finished via task_notification: " \
                     "#{action[:name]} after #{duration}s (status=#{parsed['status']})"
      rescue JSON::ParserError
        # Not JSON, ignore
      end

      def track_tool_event(line)
        parsed = JSON.parse(line)
        content_items = parsed.dig('message', 'content')
        return unless content_items.is_a?(Array)

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        content_items.each do |item|
          case item['type']
          when 'text'
            text = item['text'].to_s.strip
            unless text.empty?
              @snapshot_builder.set_message(text)
              EventStream.emit_snapshot(@snapshot_builder.to_h)
            end
          when 'thinking'
            text = item['thinking'].to_s.strip
            @snapshot_builder.set_thinking(text.empty? ? '...' : text)
            EventStream.emit_snapshot(@snapshot_builder.to_h)
          when 'tool_use'
            # Claude sends `input` as a String (not Hash) for Skill / TaskOutput. Any other
            # tool doing the same must not crash here — guard before .dig on input.
            input = item['input']
            input_hash = input.is_a?(Hash) ? input : {}
            summary = summarize_tool_input(item['name'], input)
            @snapshot_builder.set_todos(input_hash['todos']) if item['name'] == 'TodoWrite'
            @snapshot_builder.tool_started(tool_id: item['id'], name: item['name'], summary: summary,
                                           description: tool_description(item['name'], input, input_hash))
            EventStream.emit_snapshot(@snapshot_builder.to_h)
            Logger.debug "[#{@log_tag}] [tool_tracking] Tool started: #{item['name']} (#{item['id']}) #{summary}"
            check_stall(@stall_detector&.observe_tool_use(item))
          when 'tool_result'
            action = @snapshot_builder.active_actions_snapshot[item['tool_use_id']]
            if action
              duration = (now - action[:mono_started_at]).round(1)
              @snapshot_builder.tool_finished(tool_id: item['tool_use_id'])
              EventStream.emit_snapshot(@snapshot_builder.to_h)
              Logger.debug "[#{@log_tag}] [tool_tracking] Tool finished: #{action[:name]} after #{duration}s"
            end
            check_stall(@stall_detector&.observe_tool_result(item))
          end
        end
      rescue JSON::ParserError
        # Not JSON, ignore
      end

      def summarize_tool_input(name, input)
        # Skill / TaskOutput arrive with a String input (file path / task id). Other tools
        # could do the same in the future — fall through to summarize_string_input instead
        # of crashing on the Hash-only accessors below.
        return summarize_string_input(name, input) unless input.is_a?(Hash)

        raw = case name
              when 'Bash' then input['command']
              when 'Edit', 'Write', 'Read', 'NotebookEdit' then input['file_path'] || input['notebook_path']
              when 'Grep' then [input['pattern'], input['path']].compact.join(' in ')
              when 'Glob' then input['pattern']
              when 'WebFetch' then input['url']
              when 'WebSearch' then input['query']
              when 'Task' then input['description'] || input['subagent_type']
              when 'TodoWrite' then summarize_todos(input['todos'])
              when 'Skill' then input['skill']
              else input['file_path'] || input['path'] || input['query'] || input['pattern'] || input['command'] || input.values.first
        end

        truncate_summary(raw.to_s)
      end

      # Skill input arrives either as a Hash { skill:, args: } or as a String path to the
      # SKILL.md file (e.g. /Users/.../.claude/skills/code-simplifier/SKILL.md). The web card
      # must show the skill NAME (e.g. "code-simplifier") as the action summary, not the
      # file basename ("SKILL.md") — that's the user's mental model of what's running.
      def summarize_string_input(name, input)
        text = input.to_s
        return truncate_summary(text) unless name == 'Skill' && text.start_with?('/')

        truncate_summary(skill_name_from_path(text))
      end

      # Extracts the skill name from a path like /Users/.../skills/{name}/SKILL.md.
      # Falls back to the basename when the path doesn't match the expected layout so
      # an unusual layout still produces a readable summary instead of crashing.
      def skill_name_from_path(path)
        match = path.match(%r{/skills/([^/]+)/?[^/]*\z})
        match ? match[1] : File.basename(path)
      end

      # Tool description for the snapshot. For Skill with a String input (the file path)
      # the description carries the path so the web card shows it next to the skill name
      # in the summary line. For Hash inputs, prefer the tool's own description field;
      # for Skill with Hash { skill:, args: } the args go here so the user sees what was
      # passed to the skill, separately from the skill name.
      def tool_description(name, input, input_hash)
        if name == 'Skill' && input.is_a?(String) && input.start_with?('/')
          return input
        end
        if name == 'Skill' && (args = input_hash['args'])
          return args.to_s
        end

        input_hash['description']
      end

      def summarize_todos(todos)
        return '' unless todos.is_a?(Array)

        current = todos.find { |t| t['status'] == 'in_progress' } || todos.find { |t| t['status'] == 'pending' }
        current ? current['content'] : "#{todos.count} todos"
      end

      def truncate_summary(text)
        clean = text.to_s.tr("\n\r\t", ' ').squeeze(' ').strip
        clean.length > 120 ? "#{clean[0, 117]}..." : clean
      end

      def check_stall(stall)
        return unless stall
        return if @state.stalled

        @state.stalled = stall
        @state.stopping = true
        Logger.error "[#{@log_tag}] Stall detected: reason=#{stall.reason} signature=#{stall.signature} " \
                     "count=#{stall.count}#{" detail=#{stall.detail}" if stall.detail} — terminating for genius escalation"
        error_msg = "#{stall.reason}: #{stall.signature} (#{stall.count}x)#{" #{stall.detail}" if stall.detail}"
        @snapshot_builder.set_status(:stalled, error_message: error_msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
        kill_process(@state.child_pid)
        release_test_lock
      end

      def format_active_tools(now = nil)
        @snapshot_builder.format_active_tools(now)
      end

      def check_for_mcp_server_status(line)
        return unless line.include?('"subtype":"init"')

        parsed = JSON.parse(line)
        servers = parsed['mcp_servers']
        return unless servers.is_a?(Array)

        servers.each do |server|
          next unless server['status'] == 'failed'

          Logger.warn "[#{@log_tag}] MCP server '#{server['name']}' failed to initialize!"
          Logger.info_stdout "[#{@log_tag}] WARNING: MCP server '#{server['name']}' is unavailable — agent will use fallback tools"
        end
      rescue JSON::ParserError
        # Not valid JSON, ignore
      end

      def check_for_api_overload(line)
        return if @state.api_overload

        @state.api_overload = true if line.include?('"error_status": 529') ||
                                      line.include?('"error_status":529') ||
                                      line.include?('Repeated 529 Overloaded')
      end

      # Context overflow = session dead, --continue cannot recover. Kill the subprocess
      # immediately to force stdout/stderr pipe closure: without the kill, orphan child
      # processes (MCP servers, hooks) inherited from Claude can keep the pipe open
      # indefinitely after Claude itself dies, blocking stdout_thread.join forever.
      # Heartbeat also exits on @state.stopping, so the subprocess has no other watchdog.
      def check_for_context_overflow(line)
        return if @state.context_overflow
        return unless context_overflow_error?(line)

        @state.context_overflow = true
        @state.stopping = true
        Logger.error "[#{@log_tag}] Context overflow detected ('Prompt is too long') — session is dead, marking terminal"
        kill_process(@state.child_pid)
      end

      # Fire ONLY on a genuine API-level overflow. The API rejects an oversized prompt as a
      # WHOLE request, so it surfaces at the TOP LEVEL of a stream event — a result event
      # flagged is_error / subtype:error, a top-level error envelope, or (for the raw CLI) a
      # non-JSON stderr line. It NEVER arrives as a nested tool_result.
      #
      # A tool_result carrying the phrase is tool OUTPUT, not the session's own overflow, and
      # must NOT trip the kill — in TWO ways, both of which self-detonated healthy sessions:
      #   1. a *successful* Read/Grep/cat over a file documenting the phrase (e.g.
      #      claude_code_base.rb's ContextOverflowError comment) — is_error:false;
      #   2. a *failed* command (is_error:true) whose output merely quotes the phrase — e.g.
      #      `ruby bin/ci` exiting 1 with context_overflow_test.rb's own log lines in stdout.
      # The old nested-tool_result branch caught case 2 (the file/tests defining the error
      # raised it), so it is gone — only top-level / raw-CLI signals remain.
      def context_overflow_error?(line)
        return false unless line.include?('Prompt is too long') ||
                            line.include?('prompt is too long') ||
                            line.include?('context_length_exceeded')

        parsed = JSON.parse(line)
        parsed['is_error'] == true ||
          parsed['subtype'].to_s.start_with?('error') ||
          parsed.key?('error') # top-level API error envelope
      rescue JSON::ParserError
        # Non-JSON line = raw CLI/stderr text. Tool-result echoes always arrive as JSON
        # stream events, so a bare line carrying the phrase is the CLI's own API error.
        true
      end

      # MCP server disconnected at Claude startup → tool reports "exists but is not enabled
      # in this context". Marker retries would just re-emit the same failure and balloon
      # context past the 200K pin (see config/models.yml). Treat as terminal.
      # Sets snapshot status to :error inside the detector (mirrors check_stall) so
      # finalize_streaming skips re-setting :finished, and the failure shows up in the
      # mcptask.online web UI — not only in ~/logs/mcptask_runner/mcptask_runner.log.
      def check_for_tool_not_enabled(line)
        return if @state.tool_not_enabled
        return unless tool_not_enabled_error?(line)

        @state.tool_not_enabled = true
        @state.stopping = true
        error_msg = 'MCP tool not enabled — MCP server disconnected (check .mcp.json + env tokens)'
        Logger.error "[#{@log_tag}] Tool not enabled detected — #{error_msg}, session is dead, marking terminal"
        @snapshot_builder.set_status(:error, error_message: error_msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
        kill_process(@state.child_pid)
      end

      # Fire ONLY on a genuine is_error tool_result. A *successful* tool_result whose
      # content merely echoes the marker (Grep/Read/cat over a file or log quoting the
      # phrase — e.g. tool_not_enabled_test.rb itself) must NOT trip the kill. That
      # self-detection killed a healthy session: an audit grep matched the fixture
      # string and the watchdog mistook it for a real disconnect.
      def tool_not_enabled_error?(line)
        return false unless line.include?('exists but is not enabled in this context')

        blocks = JSON.parse(line).dig('message', 'content')
        blocks.is_a?(Array) && blocks.any? do |block|
          block['type'] == 'tool_result' && block['is_error'] &&
            block['content'].to_s.include?('exists but is not enabled in this context')
        end
      rescue JSON::ParserError
        false
      end

      def check_for_result_message(line)
        return if @state.result_received

        parsed = JSON.parse(line)
        return unless parsed['type'] == 'result'

        result_text = parsed['result'].to_s
        if result_text.include?('TASKRUNNER_RESULT')
          @state.result_received = true
          @state.stopping = true
          Logger.info_stdout "[#{@log_tag}] Final result received (TASKRUNNER_RESULT found), stopping streams..."
        else
          Logger.info_stdout "[#{@log_tag}] Interim result received (no TASKRUNNER_RESULT), continuing to stream..."
        end
      rescue JSON::ParserError
        # Not JSON or invalid, ignore
      end

      def extract_text_from_line(line)
        parsed = JSON.parse(line)
        if (content = parsed.dig('message', 'content'))
          content.select { |item| item['type'] == 'text' }
                 .map { |item| item['text'] }
                 .join
        elsif parsed.dig('delta', 'type') == 'text_delta'
          parsed.dig('delta', 'text') || ''
        else
          ''
        end
      rescue JSON::ParserError
        ''
      end

      def write_debug_dump(stderr_content, pid)
        timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
        dump_path = "log/debug_dump_#{timestamp}.txt"
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        sections = []
        sections << "=== DEBUG DUMP #{Time.now} ==="
        sections << "Stream event count: #{@state.stream_line_count}"
        sections << "Child PID: #{pid}"
        sections << ""

        sections << "=== ACTIVE TOOL CALLS ==="
        active_actions = @snapshot_builder.active_actions_snapshot
        if active_actions.empty?
          sections << "(none)"
        else
          active_actions.each do |id, info|
            duration = (now - info[:mono_started_at]).to_i
            sections << "  #{info[:name]} (#{id}) - waiting #{duration}s"
          end
        end
        sections << ""

        sections << "=== PROCESS TREE ==="
        sections << capture_process_tree(pid)
        sections << ""

        sections << "=== STDERR ==="
        sections << (stderr_content.empty? ? '(empty)' : stderr_content)
        sections << ""

        sections << "=== LAST 50 STREAM LINES ==="
        last_lines = (@text_content || '').lines.last(50)
        sections << (last_lines.empty? ? '(empty)' : last_lines.join)

        FileUtils.mkdir_p('log')
        File.write(dump_path, sections.join("\n"))
        Logger.info_stdout "[#{@log_tag}] Debug dump written to #{dump_path}"
      rescue StandardError => e
        Logger.warn "[#{@log_tag}] Failed to write debug dump: #{e.message}"
      end

      def capture_process_tree(pid)
        return '(no pid)' unless pid

        output = `ps -o pid,ppid,state,command -g #{pid} 2>&1`.strip
        output.empty? ? '(no processes found)' : output
      rescue StandardError => e
        "(error: #{e.message})"
      end
    end
  end
end
