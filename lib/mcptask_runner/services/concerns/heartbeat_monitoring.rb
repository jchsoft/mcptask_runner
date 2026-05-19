# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Heartbeat thread + snapshot status mutators (frozen / processing / error).
    #
    # Drives the SnapshotBuilder state machine from per-attempt streaming activity:
    # - inactive > FROZEN_WARN_THRESHOLD with no active tools → :frozen (soft warn, recoverable)
    # - any per-tool hang past its ceiling → :frozen (soft warn, recoverable)
    # - stream resumes after frozen → :processing (clears error_message)
    # - inactive ≥ INACTIVITY_TIMEOUT → :error then SIGTERM the subprocess
    # - mid-task quota crossing → :error then SIGTERM
    module HeartbeatMonitoring
      INACTIVITY_TIMEOUT = 1200 # 20 minutes - kill only if stream_line_count stops changing
      HEARTBEAT_INTERVAL = 120 # 2 minutes between heartbeat messages
      FROZEN_WARN_THRESHOLD = 180 # 3 minutes — soft warn: snapshot status=frozen, recovers on next stream event
      TOOL_HANG_TIMEOUT = 3600 # 60 minutes - long tools (Bash/Task) can run ~30min for system tests/CI/subagents
      QUICK_TOOL_HANG_TIMEOUT = 120 # 2 minutes - fast tools (MCP, Read, Edit, Grep) should respond quickly;
      # catches MCP server hangs (e.g. mcptask.online restart drops connection mid-call)
      # without waiting the full hour the long-tool ceiling allows.
      LONG_RUNNING_TOOLS = %w[Bash Task].freeze

      private

      # A running tool (e.g. long Bash/system test) counts as real activity even if Claude
      # stops streaming during it — reset the inactivity timer so we don't kill healthy tasks
      # and don't flap the UI badge. TOOL_HANG_TIMEOUT below still flags frozen if a single
      # tool genuinely hangs forever.
      def heartbeat_loop(stderr_content, execution_start)
        last_known_count = @state.stream_line_count
        last_activity_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        loop do
          sleep(HEARTBEAT_INTERVAL)
          break if @state.result_received || @state.stopping

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          current_count = @state.stream_line_count
          stream_advanced = current_count != last_known_count
          last_activity_time = now if stream_advanced || @snapshot_builder.has_active_tools?
          last_known_count = current_count
          inactive_seconds = (now - last_activity_time).to_i

          recover_from_frozen_if_resumed(stream_advanced)
          emit_heartbeat(current_count, inactive_seconds, now)
          break if heartbeat_quota_terminate(execution_start, now)
          break if terminate_for_inactivity_if_idle(current_count, inactive_seconds, stderr_content)

          mark_frozen_for_hung_tool(now)
          mark_frozen_for_inactive(inactive_seconds)
        end
      rescue StandardError => e
        Logger.debug "[#{@log_tag}] Heartbeat thread error: #{e.message}"
      end

      def emit_heartbeat(current_count, inactive_seconds, now)
        tool_info = @snapshot_builder.format_active_tools(now)
        Logger.info_stdout "[#{@log_tag}] [heartbeat] Claude is working... " \
                           "(#{current_count} stream events, inactive: #{inactive_seconds}s#{tool_info})"
        @snapshot_builder.mark_activity
        EventStream.emit_snapshot(@snapshot_builder.to_h)
      end

      def mark_frozen_for_hung_tool(now)
        hung = hung_tool(now)
        return unless hung
        return if @snapshot_builder.status == "frozen"

        elapsed = (now - hung[:mono_started_at]).to_i
        msg = "Tool #{hung[:name]} hung for #{elapsed}s"
        Logger.warn "[#{@log_tag}] #{msg} (>#{tool_hang_timeout_for(hung[:name])}s), marking frozen"
        @snapshot_builder.set_status(:frozen, error_message: msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
      end

      def mark_frozen_for_inactive(inactive_seconds)
        return unless inactive_seconds > FROZEN_WARN_THRESHOLD
        return if @snapshot_builder.has_active_tools?
        return if @snapshot_builder.status == "frozen"

        msg = "No stream activity for #{inactive_seconds}s"
        Logger.warn "[#{@log_tag}] #{msg}, marking frozen"
        @snapshot_builder.set_status(:frozen, error_message: msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
      end

      def recover_from_frozen_if_resumed(stream_advanced)
        return unless stream_advanced
        return unless @snapshot_builder.status == "frozen"

        Logger.info_stdout "[#{@log_tag}] Stream resumed; clearing frozen status"
        @snapshot_builder.set_status(:processing)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
      end

      def terminate_for_inactivity_if_idle(current_count, inactive_seconds, stderr_content)
        return false unless inactive_seconds >= INACTIVITY_TIMEOUT

        msg = "Inactivity timeout — killing subprocess"
        Logger.error "[#{@log_tag}] Claude inactive for #{inactive_seconds}s " \
                     "(stream count stuck at #{current_count}), terminating..."
        @snapshot_builder.set_status(:error, error_message: msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
        terminate_for_inactivity(stderr_content)
        true
      end

      def terminate_for_inactivity(stderr_content)
        write_debug_dump(stderr_content, @state.child_pid)
        @state.stopping = true
        @state.inactivity_timeout = true
        kill_process(@state.child_pid)
        release_test_lock
      end

      def heartbeat_quota_terminate(execution_start, now)
        return false unless quota_exceeded_now?(execution_start, now)

        watch = @quota_watch
        elapsed_h = ((now - execution_start) / 3600.0).round(2)
        Logger.error "[#{@log_tag}] Daily quota exceeded mid-task " \
                     "(per_day=#{watch[:per_day_hours]}h, already_worked=#{watch[:already_worked_hours]}h, " \
                     "this_run=#{elapsed_h}h), terminating..."
        @state.stopping = true
        @state.quota_exceeded = true
        kill_process(@state.child_pid)
        release_test_lock
        true
      end

      def hung_tool(now)
        @snapshot_builder.active_actions_snapshot.each_value do |info|
          return info if (now - info[:mono_started_at]) >= tool_hang_timeout_for(info[:name])
        end
        nil
      end

      def tool_hang_timeout_for(name)
        LONG_RUNNING_TOOLS.include?(name) ? TOOL_HANG_TIMEOUT : QUICK_TOOL_HANG_TIMEOUT
      end
    end
  end
end
