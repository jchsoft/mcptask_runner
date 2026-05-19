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

  def test_mark_frozen_for_hung_tool_sets_frozen_without_kill
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
      base.send(:mark_frozen_for_hung_tool, now)
    end

    assert_equal "frozen", builder.status
    refute base.instance_variable_get(:@state).stopping, "Hung-tool warning must not kill subprocess"
    refute base.instance_variable_get(:@state).inactivity_timeout, "Hung-tool must not flip inactivity_timeout"
  end

  def test_mark_frozen_for_hung_tool_skips_when_already_frozen
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:frozen, error_message: "earlier reason")
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "Bash", summary: "", mono_started_at: now - 4000, started_at: Time.now.utc.iso8601(3)
    }

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snap, **_kw) { emitted << snap }) do
      base.send(:mark_frozen_for_hung_tool, now)
    end

    assert_empty emitted
  end

  def test_recover_from_frozen_if_resumed_transitions_back_to_processing
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:frozen, error_message: "stale")

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_frozen_if_resumed, true)
    end

    assert_equal "processing", builder.status
    assert_nil builder.to_h[:error_message], "Recovery must clear error_message"
  end

  def test_recover_from_frozen_if_resumed_noop_when_stream_idle
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:frozen, error_message: "stale")

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_frozen_if_resumed, false)
    end

    assert_equal "frozen", builder.status
  end

  def test_recover_from_frozen_if_resumed_noop_when_not_frozen
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:recover_from_frozen_if_resumed, true)
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
end
