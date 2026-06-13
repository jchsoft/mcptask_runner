# frozen_string_literal: true

require "json"

module McptaskRunner
  module Concerns
    # Heartbeat thread + snapshot status mutators (pending / frozen / processing / error).
    #
    # Drives the SnapshotBuilder state machine from per-attempt streaming activity:
    # - inactive > FROZEN_WARN_THRESHOLD with no active tools → :frozen (stream stuck, recoverable)
    # - per-tool hang past its WARN ceiling → :pending (tool slow, recoverable, soft warn)
    # - stream resumes after pending/frozen → :processing (clears error_message)
    # - inactive ≥ INACTIVITY_TIMEOUT → :error then SIGTERM the subprocess
    # - per-tool hang past its KILL ceiling AND stream quiet ≥ STREAM_QUIET_KILL → :error + SIGTERM
    # - mid-task quota crossing → :error then SIGTERM
    module HeartbeatMonitoring
      INACTIVITY_TIMEOUT = 1200 # 20 minutes - kill only if stream_line_count stops changing
      HEARTBEAT_INTERVAL = 30 # 30 seconds between heartbeat messages
      FROZEN_WARN_THRESHOLD = 180 # 3 minutes — soft warn: stream stuck (no active tools); status=frozen
      # How long the stream must be quiet (no new lines) before hung-tool warn/kill may fire.
      # Without this gate, an orphan tool entry (Claude Code occasionally never emits tool_result
      # for a Skill / forked execution) would trigger SIGTERM even while Claude is clearly alive,
      # firing new tools. Stream advancing = Claude responsive = no kill.
      STREAM_QUIET_KILL_THRESHOLD = 180 # 3 minutes
      # Absolute backstop: kill after this many seconds of ZERO new stream output, regardless of
      # whether a tool is "active". Set ABOVE the longest legit per-tool ceiling (long kill 1500s)
      # so genuine long Bash/CI runs are still caught by their own ceiling, while a truly silent or
      # untracked hang (e.g. an MCP SSE call that never returns, the heartbeat-thread-died case)
      # dies no matter what. This is the deadline that does NOT care about has_active_tools?.
      ABSOLUTE_SILENCE_KILL = 3000 # 50 minutes — floor for long CI / system suites; adaptive ceiling raises it further
      # The static long-tool ceiling (1500s) is too tight for projects whose CI / system tests
      # legitimately run past 30 min. The test-runner/ci-runner skills already record real run
      # durations in tmp/test_durations.json; reuse them (same ×1.5 safety factor the skills apply)
      # so the kill ceiling self-tunes per project — fast projects keep the tight default, CI-heavy
      # ones get headroom — without a hand-maintained config. Capped so a bogus entry can't disable
      # the watchdog entirely.
      TEST_DURATIONS_FILE = "tmp/test_durations.json"
      ADAPTIVE_CEILING_FACTOR = 1.5
      ADAPTIVE_CEILING_CAP = 5400 # 90 minutes — hard ceiling regardless of recorded durations
      # interval: live REST quota re-check cadence during a task (~6 min).
      # failure_kill_streak: consecutive REST failures before fail-closed mid-task kill (~18 min outage).
      QUOTA_POLL = { interval: 360, failure_kill_streak: 3 }.freeze
      # Per-tool ceilings (seconds). :warn → status=:pending (soft warn).
      # :kill → status=:error + SIGTERM. Quick = MCP/Read/Edit/Grep. Long = Bash/Task.
      # Long :kill is the FLOOR for CI / system suites (which routinely run 25–45 min); the adaptive
      # ceiling from tmp/test_durations.json only ever raises it, so targeted/killed runs that never
      # record a duration are still given this much headroom before a kill.
      TOOL_HANG_TIMEOUTS = { quick: { warn: 120, kill: 300 }, long: { warn: 600, kill: 2700 } }.freeze
      # Tools that legitimately run long: Bash (CI/system tests), Task (subagents),
      # Skill (forked sub-skill execution like ci-wait/test-wait can poll up to 9 min each),
      # TaskOutput (polls output from long-running sub-tasks / background commands — itself
      # can block for the full duration of whatever it is tailing, easily 10+ minutes for CI).
      LONG_RUNNING_TOOLS = %w[Bash Task Skill TaskOutput].freeze

      private

      # A running tool (e.g. long Bash/system test) counts as real activity even if Claude
      # stops streaming during it — reset the inactivity timer so we don't kill healthy tasks
      # and don't flap the UI badge. TOOL_HANG_TIMEOUTS warn/kill ceilings still catch a
      # single tool that genuinely hangs forever (status → pending → error+SIGTERM).
      # Supervised watchdog thread. The whole point: it MUST NOT die silently. Any StandardError
      # that escapes heartbeat_loop is logged loudly and the loop is restarted (unless the run is
      # already finishing), so a single transient throw can never leave the run unmonitored — the
      # exact failure that let two runners hang for 90 minutes on a stuck MCP call.
      def start_supervised_heartbeat(stderr_content, execution_start)
        Thread.new do
          heartbeat_loop(stderr_content, execution_start)
        rescue StandardError => e
          Logger.error "[#{@log_tag}] Heartbeat thread crashed: #{e.class}: #{e.message} — restarting watchdog"
          retry unless @state.result_received || @state.stopping
        end
      end

      def heartbeat_loop(stderr_content, execution_start)
        last_known_count = @state.stream_line_count
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        last_activity_time = now
        last_stream_time = now

        loop do
          sleep(HEARTBEAT_INTERVAL)
          break if @state.result_received || @state.stopping

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          current_count = @state.stream_line_count
          stream_advanced = current_count != last_known_count
          last_activity_time = now if stream_advanced || @snapshot_builder.has_active_tools?
          last_stream_time = now if stream_advanced
          last_known_count = current_count

          timing = {
            now: now, current_count: current_count, stream_advanced: stream_advanced,
            inactive_seconds: (now - last_activity_time).to_i,
            stream_quiet_seconds: (now - last_stream_time).to_i
          }
          break if heartbeat_tick(timing, stderr_content)
        end
      end

      # One monitoring cycle, fully guarded: safety kill-decisions run FIRST (they read only
      # @state + the monotonic clock + active_actions), then best-effort observability. A throw
      # anywhere is logged and swallowed so the loop survives to the next cycle — the safety net
      # is never starved by a failing snapshot emit or quota poll. Returns true to end the loop.
      def heartbeat_tick(timing, stderr_content)
        return true if enforce_safety_deadlines(timing, stderr_content)

        update_observability(timing)
        false
      rescue StandardError => e
        Logger.error "[#{@log_tag}] Heartbeat tick error (continuing): #{e.class}: #{e.message}"
        false
      end

      # Kill decisions, in priority order. Returns true if the subprocess was terminated.
      def enforce_safety_deadlines(timing, stderr_content)
        return true if heartbeat_quota_terminate(timing[:now])
        return true if terminate_for_inactivity_if_idle(timing[:current_count], timing[:inactive_seconds], stderr_content)
        return true if terminate_for_stream_silence(timing[:stream_quiet_seconds], stderr_content)
        return true if terminate_for_hung_tool_if_dead(timing[:now], stderr_content, timing[:stream_quiet_seconds])

        false
      end

      # Best-effort status/observability — never affects the kill decision.
      def update_observability(timing)
        recover_from_soft_warn_if_resumed(timing[:stream_advanced])
        emit_heartbeat(timing[:current_count], timing[:inactive_seconds], timing[:now])
        refresh_run_log(timing)
        mark_pending_for_hung_tool(timing[:now], timing[:stream_quiet_seconds])
        mark_frozen_for_inactive(timing[:inactive_seconds])
      end

      # Absolute backstop kill: ZERO new stream output for ABSOLUTE_SILENCE_KILL seconds, no matter
      # whether a tool is flagged active. Catches hangs the per-tool ceilings miss (untracked tool,
      # or — historically — a dead heartbeat thread that came back via the supervisor).
      def terminate_for_stream_silence(stream_quiet_seconds, stderr_content)
        return false if stream_quiet_seconds < absolute_silence_ceiling

        Logger.error "[#{@log_tag}] No stream output for #{stream_quiet_seconds}s " \
                     "(absolute silence backstop > #{absolute_silence_ceiling}s), terminating..."
        @snapshot_builder.set_status(:error, error_message: "Absolute stream-silence timeout — killing subprocess")
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
        terminate_for_inactivity(stderr_content)
        true
      end

      def refresh_run_log(timing)
        @run_log&.refresh(
          snapshot: @snapshot_builder.to_h,
          timing: { stream_events: timing[:current_count], inactive_s: timing[:inactive_seconds],
                    stream_quiet_s: timing[:stream_quiet_seconds] }
        )
      end

      def emit_heartbeat(current_count, inactive_seconds, now)
        tool_info = @snapshot_builder.format_active_tools(now)
        Logger.info_stdout "[#{@log_tag}] [heartbeat] Claude is working... " \
                           "(#{current_count} stream events, inactive: #{inactive_seconds}s#{tool_info})"
        @snapshot_builder.mark_activity
        EventStream.emit_snapshot(@snapshot_builder.to_h)
      end

      def mark_pending_for_hung_tool(now, stream_quiet_seconds)
        return if stream_quiet_seconds < STREAM_QUIET_KILL_THRESHOLD

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

      def heartbeat_quota_terminate(now)
        return false unless quota_exceeded_now?(now)

        Logger.error "[#{@log_tag}] Daily quota exceeded mid-task (live REST) — terminating subprocess"
        @state.stopping = true
        @state.quota_exceeded = true
        kill_process(@state.child_pid)
        release_test_lock
        true
      end

      # Mid-task quota check, throttled to one live REST poll per QUOTA_POLL_INTERVAL.
      # Authoritative worked_today comes straight from mcptask.online — never from the
      # agent — so a child that under-reports its own hours can't dodge the cap.
      # Fail-closed on REST errors, but only after QUOTA_FAILURE_KILL_STREAK consecutive
      # misses so a single transient blip doesn't nuke healthy in-flight work.
      def quota_exceeded_now?(now)
        return false unless @quota_watch
        return false if (now - @last_quota_poll_at) < QUOTA_POLL[:interval]

        @last_quota_poll_at = now
        status = QuotaGuard.status
        @snapshot_builder.set_quota(per_day_hours: status.per_day, already_worked_hours: status.worked_today) if status.rest_ok
        reached_quota_kill?(status)
      end

      def reached_quota_kill?(status)
        if status.rest_ok
          @quota_rest_failures = 0
          return status.exceeded
        end

        @quota_rest_failures += 1
        @quota_rest_failures >= QUOTA_POLL[:failure_kill_streak]
      end

      def hung_tool(now)
        tool = newest_active_tool
        return nil unless tool

        (now - tool[:mono_started_at]) >= tool_hang_timeout_for(tool[:name]) ? tool : nil
      end

      # The only tool Claude is actually blocked on is the most-recently-started one. Older entries
      # that linger past it are orphans — Claude Code sometimes never emits a tool_result for a forked
      # Skill, so a stale entry can sit "active" for the whole run while Claude fires fresh tools and
      # is plainly alive. Judging liveness by the newest tool means those orphans can never trigger a
      # kill while newer work proves the child responsive; a genuine hang still surfaces because
      # nothing newer gets issued, so the newest entry's own age crosses the ceiling.
      def newest_active_tool
        @snapshot_builder.active_actions_snapshot.values.max_by { |info| info[:mono_started_at] }
      end

      def tool_hang_timeout_for(name)
        TOOL_HANG_TIMEOUTS[tool_category(name)][:warn]
      end

      def terminate_for_hung_tool_if_dead(now, stderr_content, stream_quiet_seconds)
        return false if stream_quiet_seconds < STREAM_QUIET_KILL_THRESHOLD

        dead = dead_tool(now)
        return false unless dead

        elapsed = (now - dead[:mono_started_at]).to_i
        msg = "Tool #{dead[:name]} hung #{elapsed}s — killing subprocess (stream quiet #{stream_quiet_seconds}s)"
        Logger.error "[#{@log_tag}] #{msg} (>#{tool_kill_timeout_for(dead[:name])}s)"
        @snapshot_builder.set_status(:error, error_message: msg)
        EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
        terminate_for_inactivity(stderr_content)
        true
      end

      def dead_tool(now)
        tool = newest_active_tool
        return nil unless tool

        (now - tool[:mono_started_at]) >= tool_kill_timeout_for(tool[:name]) ? tool : nil
      end

      def tool_kill_timeout_for(name)
        return long_tool_kill_ceiling if tool_category(name) == :long

        TOOL_HANG_TIMEOUTS[:quick][:kill]
      end

      def tool_category(name)
        LONG_RUNNING_TOOLS.include?(name) ? :long : :quick
      end

      # Adaptive long-tool kill ceiling: never tighter than the static default, raised toward the
      # project's longest recorded run when that exceeds it, capped at ADAPTIVE_CEILING_CAP.
      def long_tool_kill_ceiling
        @long_tool_kill_ceiling ||= [TOOL_HANG_TIMEOUTS[:long][:kill], recorded_run_ceiling].max
      end

      # Absolute-silence backstop sits a margin above the long-tool ceiling so a genuine long run is
      # caught by its own ceiling first, not the blanket silence kill.
      def absolute_silence_ceiling
        @absolute_silence_ceiling ||= [ABSOLUTE_SILENCE_KILL, long_tool_kill_ceiling + 300].max
      end

      # Longest recorded test/CI duration (ms) × safety factor, in seconds; 0 when the file is
      # absent or unreadable, so we fall back to the static constant. A missing/partial file is the
      # normal case (most runs never write it), not a programmer error — degrade quietly.
      def recorded_run_ceiling
        durations = JSON.parse(File.read(File.join(Dir.pwd, TEST_DURATIONS_FILE)))
        longest_ms = durations.values.flat_map { |entry| entry.values_at("last_duration_ms", "max_duration_ms") }.compact.max
        return 0 unless longest_ms

        [(longest_ms * ADAPTIVE_CEILING_FACTOR / 1000).to_i, ADAPTIVE_CEILING_CAP].min
      rescue Errno::ENOENT, JSON::ParserError
        0
      end
    end
  end
end
