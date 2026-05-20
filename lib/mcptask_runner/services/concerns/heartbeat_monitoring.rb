# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Heartbeat thread + snapshot status mutators (pending / frozen / processing / error).
    #
    # Drives the SnapshotBuilder state machine from per-attempt streaming activity:
    # - inactive > FROZEN_WARN_THRESHOLD with no active tools → :frozen (stream stuck, recoverable)
    # - per-tool hang past its WARN ceiling → :pending (tool slow, recoverable, soft warn)
    # - stream resumes after pending/frozen → :processing (clears error_message)
    # - inactive ≥ INACTIVITY_TIMEOUT → :error then SIGTERM the subprocess
    # - per-tool hang past its KILL ceiling → :error then SIGTERM (hung-tool escalation)
    # - mid-task quota crossing → :error then SIGTERM
    module HeartbeatMonitoring
      INACTIVITY_TIMEOUT = 1200 # 20 minutes - kill only if stream_line_count stops changing
      HEARTBEAT_INTERVAL = 120 # 2 minutes between heartbeat messages
      FROZEN_WARN_THRESHOLD = 180 # 3 minutes — soft warn: stream stuck (no active tools); status=frozen
      # Per-tool ceilings (seconds). :warn → status=:pending (soft warn).
      # :kill → status=:error + SIGTERM. Quick = MCP/Read/Edit/Grep. Long = Bash/Task.
      TOOL_HANG_TIMEOUTS = { quick: { warn: 120, kill: 300 }, long: { warn: 600, kill: 1500 } }.freeze
      LONG_RUNNING_TOOLS = %w[Bash Task].freeze

      private

      # A running tool (e.g. long Bash/system test) counts as real activity even if Claude
      # stops streaming during it — reset the inactivity timer so we don't kill healthy tasks
      # and don't flap the UI badge. TOOL_HANG_TIMEOUTS warn/kill ceilings still catch a
      # single tool that genuinely hangs forever (status → pending → error+SIGTERM).
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

          recover_from_soft_warn_if_resumed(stream_advanced)
          emit_heartbeat(current_count, inactive_seconds, now)
          break if heartbeat_quota_terminate(execution_start, now)
          break if terminate_for_inactivity_if_idle(current_count, inactive_seconds, stderr_content)
          break if terminate_for_hung_tool_if_dead(now, stderr_content)

          mark_pending_for_hung_tool(now)
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

      def mark_pending_for_hung_tool(now)
        hung = hung_tool(now)
        return unless hung
        return if @snapshot_builder.status == "pending"

        elapsed = (now - hung[:mono_started_at]).to_i
        msg = "Tool #{hung[:name]} pending for #{elapsed}s"
        Logger.warn "[#{@log_tag}] #{msg} (>#{tool_hang_timeout_for(hung[:name])}s), marking pending"
        @snapshot_builder.set_status(:pending, error_message: msg)
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

      def recover_from_soft_warn_if_resumed(stream_advanced)
        return unless stream_advanced
        return unless %w[frozen pending].include?(@snapshot_builder.status)

        Logger.info_stdout "[#{@log_tag}] Stream resumed; clearing #{@snapshot_builder.status} status"
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
        TOOL_HANG_TIMEOUTS[tool_category(name)][:warn]
      end

      def terminate_for_hung_tool_if_dead(now, stderr_content)
        dead = dead_tool(now)
        return false unless dead

        elapsed = (now - dead[:mono_started_at]).to_i
        msg = "Tool #{dead[:name]} hung #{elapsed}s — killing subprocess"
        Logger.error "[#{@log_tag}] #{msg} (>#{tool_kill_timeout_for(dead[:name])}s)"
        @snapshot_builder.set_status(:error, error_message: msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
        terminate_for_inactivity(stderr_content)
        true
      end

      def dead_tool(now)
        @snapshot_builder.active_actions_snapshot.each_value do |info|
          return info if (now - info[:mono_started_at]) >= tool_kill_timeout_for(info[:name])
        end
        nil
      end

      def tool_kill_timeout_for(name)
        TOOL_HANG_TIMEOUTS[tool_category(name)][:kill]
      end

      def tool_category(name)
        LONG_RUNNING_TOOLS.include?(name) ? :long : :quick
      end
    end
  end
end
