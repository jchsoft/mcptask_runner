# frozen_string_literal: true

require 'test_helper'

# Heartbeat-driven snapshot status mutation: frozen warn, recovery, error+kill on inactivity.
# See task #10361 — server-side freeze/idle decision moved into the runner heartbeat thread.
class ClaudeCodeBaseHeartbeatTest < Minitest::Test
  def test_frozen_warn_threshold_constant_is_defined
    assert_equal 180, McptaskRunner::ClaudeCodeBase::FROZEN_WARN_THRESHOLD
  end

  def test_mark_frozen_for_inactive_sets_frozen_status_after_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:mark_frozen_for_inactive, 200) # 200s > 180s threshold
    end

    assert_equal "frozen", builder.status
  end

  def test_mark_frozen_for_inactive_skips_when_below_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:mark_frozen_for_inactive, 60) # under threshold
    end

    assert_equal "processing", builder.status
  end

  def test_mark_frozen_for_inactive_skips_when_active_tools_present
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.tool_started(tool_id: "t1", name: "Bash", summary: "")

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:mark_frozen_for_inactive, 500)
    end

    assert_equal "processing", builder.status
  end

  def test_mark_frozen_for_inactive_does_not_re_emit_when_already_frozen
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:frozen, error_message: "first")

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snap, **_kw) { emitted << snap }) do
      base.send(:mark_frozen_for_inactive, 400)
    end

    assert_empty emitted, "Already-frozen heartbeat must not re-emit/re-transition"
  end

  def test_mark_pending_for_hung_tool_sets_pending_without_kill
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 200, started_at: Time.now.utc.iso8601(3)
    }

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:mark_pending_for_hung_tool, now, 300)
    end

    assert_equal "pending", builder.status
    refute base.instance_variable_get(:@state).stopping, "Hung-tool warning must not kill subprocess"
    refute base.instance_variable_get(:@state).inactivity_timeout, "Hung-tool must not flip inactivity_timeout"
  end

  def test_mark_pending_for_hung_tool_skips_when_already_pending
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:pending, error_message: "earlier reason")
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "Bash", summary: "", mono_started_at: now - 800, started_at: Time.now.utc.iso8601(3)
    }

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snap, **_kw) { emitted << snap }) do
      base.send(:mark_pending_for_hung_tool, now, 300)
    end

    assert_empty emitted
  end

  def test_recover_from_soft_warn_if_resumed_transitions_back_to_processing_from_frozen
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:frozen, error_message: "stale")

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_soft_warn_if_resumed, true)
    end

    assert_equal "processing", builder.status
    assert_nil builder.to_h[:error_message], "Recovery must clear error_message"
  end

  def test_recover_from_soft_warn_if_resumed_transitions_back_to_processing_from_pending
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:pending, error_message: "tool slow")

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_soft_warn_if_resumed, true)
    end

    assert_equal "processing", builder.status
    assert_nil builder.to_h[:error_message]
  end

  def test_recover_from_soft_warn_if_resumed_noop_when_stream_idle
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:frozen, error_message: "stale")

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_soft_warn_if_resumed, false)
    end

    assert_equal "frozen", builder.status
  end

  def test_recover_from_soft_warn_if_resumed_noop_when_not_soft_warn
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_soft_warn_if_resumed, true)
    end

    assert_equal "processing", builder.status
  end

  def test_terminate_for_inactivity_if_idle_marks_error_before_kill
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    inactive = McptaskRunner::ClaudeCodeBase::INACTIVITY_TIMEOUT + 10

    base.stub(:kill_process, nil) do
      base.stub(:release_test_lock, nil) do
        base.stub(:write_debug_dump, nil) do
          McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
            assert base.send(:terminate_for_inactivity_if_idle, 0, inactive, "")
          end
        end
      end
    end

    assert_equal "error", builder.status
    assert_equal "Inactivity timeout — killing subprocess", builder.to_h[:error_message]
    assert base.instance_variable_get(:@state).inactivity_timeout
    assert base.instance_variable_get(:@state).stopping
  end

  def test_terminate_for_inactivity_if_idle_returns_false_when_within_window
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    refute base.send(:terminate_for_inactivity_if_idle, 0, 60, "")
    assert_equal "processing", builder.status
  end

  def test_terminate_for_hung_tool_if_dead_kills_quick_tool_past_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 400, started_at: Time.now.utc.iso8601(3) # > HUNG_TOOL_KILL_QUICK (300)
    }

    base.stub(:kill_process, nil) do
      base.stub(:release_test_lock, nil) do
        base.stub(:write_debug_dump, nil) do
          McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
            assert base.send(:terminate_for_hung_tool_if_dead, now, "", 300)
          end
        end
      end
    end

    assert_equal "error", builder.status
    assert_match(/hung 400s/, builder.to_h[:error_message])
    assert base.instance_variable_get(:@state).stopping
    assert base.instance_variable_get(:@state).inactivity_timeout
  end

  def test_terminate_for_hung_tool_if_dead_kills_long_tool_past_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "Bash", summary: "", mono_started_at: now - 1600, # > HUNG_TOOL_KILL_LONG (1500)
      started_at: Time.now.utc.iso8601(3)
    }

    base.stub(:kill_process, nil) do
      base.stub(:release_test_lock, nil) do
        base.stub(:write_debug_dump, nil) do
          McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
            assert base.send(:terminate_for_hung_tool_if_dead, now, "", 300)
          end
        end
      end
    end

    assert_equal "error", builder.status
    assert base.instance_variable_get(:@state).stopping
  end

  def test_terminate_for_hung_tool_if_dead_skips_quick_tool_below_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 200, started_at: Time.now.utc.iso8601(3) # < 300 quick kill
    }

    refute base.send(:terminate_for_hung_tool_if_dead, now, "", 300)
    assert_equal "processing", builder.status
  end

  def test_terminate_for_hung_tool_if_dead_skips_long_tool_below_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "Bash", summary: "", mono_started_at: now - 600, # < 1500 long kill
      started_at: Time.now.utc.iso8601(3)
    }

    refute base.send(:terminate_for_hung_tool_if_dead, now, "", 300)
    assert_equal "processing", builder.status
  end

  # Polling Skill loops (ci-wait/test-wait) leave stale active_actions entries — Claude Code
  # sometimes never re-emits tool_result. While Claude keeps streaming new tool calls,
  # SIGTERMing the parent because of a stale entry is wrong. Gate kill on stream quiet.
  def test_terminate_for_hung_tool_if_dead_skips_when_stream_recently_advanced
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["stale_skill"] = {
      name: "Skill", summary: "ci-wait", mono_started_at: now - 1600,
      started_at: Time.now.utc.iso8601(3)
    }

    refute base.send(:terminate_for_hung_tool_if_dead, now, "", 60),
           "Tool past kill ceiling must NOT trigger kill when stream is still advancing"
    assert_equal "processing", builder.status
    refute base.instance_variable_get(:@state).stopping
  end

  def test_terminate_for_hung_tool_if_dead_fires_when_stream_quiet_long_enough
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 400, started_at: Time.now.utc.iso8601(3)
    }

    base.stub(:kill_process, nil) do
      base.stub(:release_test_lock, nil) do
        base.stub(:write_debug_dump, nil) do
          McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
            assert base.send(:terminate_for_hung_tool_if_dead, now, "",
                             McptaskRunner::ClaudeCodeBase::STREAM_QUIET_KILL_THRESHOLD + 10)
          end
        end
      end
    end

    assert_equal "error", builder.status
  end

  def test_mark_pending_for_hung_tool_skips_when_stream_recently_advanced
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 200, started_at: Time.now.utc.iso8601(3)
    }

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:mark_pending_for_hung_tool, now, 60)
    end

    assert_equal "processing", builder.status,
                 "pending warn must not fire while Claude stream is fresh"
  end

  def test_stream_quiet_kill_threshold_constant_is_defined
    assert_equal 180, McptaskRunner::ClaudeCodeBase::STREAM_QUIET_KILL_THRESHOLD
  end

  def test_terminate_for_hung_tool_if_dead_escalates_from_pending_to_error
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:pending, error_message: "earlier hung warn")
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 500, started_at: Time.now.utc.iso8601(3)
    }

    base.stub(:kill_process, nil) do
      base.stub(:release_test_lock, nil) do
        base.stub(:write_debug_dump, nil) do
          McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
            assert base.send(:terminate_for_hung_tool_if_dead, now, "", 300)
          end
        end
      end
    end

    assert_equal "error", builder.status
  end

  def test_absolute_silence_kill_constant_is_defined
    assert_equal 1800, McptaskRunner::ClaudeCodeBase::ABSOLUTE_SILENCE_KILL
  end

  # The backstop the watchdog was missing: kill on prolonged stream silence even while a tool
  # is still flagged active (the stuck-MCP-call shape that hung two runners for 90 min).
  def test_terminate_for_stream_silence_kills_even_with_active_tool
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "mcp__mcptask-online__LogWorkProgressTool", summary: "",
      mono_started_at: now - 100, started_at: Time.now.utc.iso8601(3)
    }

    quiet = McptaskRunner::ClaudeCodeBase::ABSOLUTE_SILENCE_KILL + 10
    base.stub(:kill_process, nil) do
      base.stub(:release_test_lock, nil) do
        base.stub(:write_debug_dump, nil) do
          McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
            assert base.send(:terminate_for_stream_silence, quiet, "")
          end
        end
      end
    end

    assert_equal "error", builder.status
    assert_match(/stream-silence/, builder.to_h[:error_message])
    assert base.instance_variable_get(:@state).stopping
    assert base.instance_variable_get(:@state).inactivity_timeout
  end

  def test_terminate_for_stream_silence_skips_below_threshold
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    refute base.send(:terminate_for_stream_silence, 60, "")
    assert_equal "processing", builder.status
  end

  def test_heartbeat_tick_returns_true_when_safety_terminates
    base = McptaskRunner::ClaudeCodeBase.new
    base.stub(:enforce_safety_deadlines, true) do
      assert base.send(:heartbeat_tick, timing_hash, "")
    end
  end

  def test_heartbeat_tick_runs_observability_and_returns_false_when_safe
    base = McptaskRunner::ClaudeCodeBase.new
    observed = false
    base.stub(:enforce_safety_deadlines, false) do
      base.stub(:update_observability, ->(_t) { observed = true }) do
        refute base.send(:heartbeat_tick, timing_hash, "")
      end
    end
    assert observed, "observability runs when no kill fired"
  end

  # A throw inside a tick must NOT kill the watchdog — it logs and the loop survives to the
  # next cycle. This is the regression that let the heartbeat thread die for the rest of a run.
  def test_heartbeat_tick_swallows_exceptions_and_continues
    base = McptaskRunner::ClaudeCodeBase.new
    base.stub(:enforce_safety_deadlines, ->(*) { raise "transient quota REST blip" }) do
      McptaskRunner::Logger.stub(:error, nil) do
        refute base.send(:heartbeat_tick, timing_hash, ""), "raising tick is swallowed, loop continues"
      end
    end
  end

  # Supervisor restarts heartbeat_loop after a crash until the run is stopping.
  def test_supervised_heartbeat_restarts_after_crash
    base = McptaskRunner::ClaudeCodeBase.new
    state = base.instance_variable_get(:@state)
    calls = 0
    McptaskRunner::Logger.stub(:error, nil) do
      base.stub(:heartbeat_loop, lambda { |*|
        calls += 1
        state.stopping = true if calls >= 2
        raise "boom" if calls < 2
      }) do
        base.send(:start_supervised_heartbeat, "", 0.0).join(2)
      end
    end
    assert_operator calls, :>=, 2, "watchdog must restart heartbeat_loop after a crash"
  end

  private

  def timing_hash
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    { now: now, current_count: 10, stream_advanced: false, inactive_seconds: 0, stream_quiet_seconds: 0 }
  end
end
