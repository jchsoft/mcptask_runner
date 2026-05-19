# frozen_string_literal: true

require "test_helper"

class EventStreamTest < Minitest::Test
  def setup
    McptaskRunner::EventStream.instance_variable_set(:@ws, nil)
    McptaskRunner::EventStream.instance_variable_set(:@subscribed, false)
    McptaskRunner::EventStream.instance_variable_set(:@mcp_json, nil)
    McptaskRunner::EventStream.instance_variable_set(:@session_id, "test-session-id")
    McptaskRunner::EventStream.instance_variable_set(:@machine_id, "test-machine")
    McptaskRunner::EventStream.instance_variable_set(:@last_reconnect_attempt, nil)
    McptaskRunner::EventStream.instance_variable_set(:@last_snapshot_emit, nil)
    McptaskRunner::EventStream.instance_variable_set(:@last_snapshot, nil)
    McptaskRunner::EventStream.instance_variable_set(:@last_emitted_status, nil)
    McptaskRunner::EventStream.instance_variable_set(:@mutex, Mutex.new)
    McptaskRunner::EventStream.instance_variable_set(:@subscribed_cv, ConditionVariable.new)
  end

  def test_disabled_when_cable_url_not_set
    with_env("MCPT_RUNNER_CABLE_URL" => nil, "MCPTASK_TOKEN" => nil) do
      refute McptaskRunner::EventStream.enabled?
    end
  end

  def test_enabled_when_cable_url_and_token_set
    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      assert McptaskRunner::EventStream.enabled?
    end
  end

  def test_disabled_when_token_missing
    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => nil) do
      refute McptaskRunner::EventStream.enabled?
    end
  end

  def test_auto_resolves_url_from_mcp_json
    fake_mcp = {
      "mcpServers" => {
        "mcptask-online" => {
          "url" => "https://mcptask.online/mcp/sse",
          "headers" => { "Authorization" => "Bearer ${MCPTASK_TOKEN}" }
        }
      }
    }
    McptaskRunner::EventStream.instance_variable_set(:@mcp_json, fake_mcp)
    with_env("MCPT_RUNNER_CABLE_URL" => nil, "MCPTASK_TOKEN" => "abc") do
      assert McptaskRunner::EventStream.enabled?
      assert_equal "wss://mcptask.online/cable",
                   McptaskRunner::EventStream.send(:resolved_cable_url)
    end
  end

  def test_start_session_noop_when_disabled
    with_env("MCPT_RUNNER_CABLE_URL" => nil, "MCPTASK_TOKEN" => nil) do
      McptaskRunner::EventStream.start_session(mode: :honest)
    end
  end

  def test_emit_snapshot_noop_when_disabled
    with_env("MCPT_RUNNER_CABLE_URL" => nil, "MCPTASK_TOKEN" => nil) do
      McptaskRunner::EventStream.emit_snapshot({ status: "starting" })
    end
  end

  def test_emit_snapshot_noop_when_ws_not_connected
    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.instance_variable_set(:@ws, nil)
      McptaskRunner::EventStream.emit_snapshot({ status: "starting" })
    end
  end

  def test_end_session_noop_when_disabled
    with_env("MCPT_RUNNER_CABLE_URL" => nil, "MCPTASK_TOKEN" => nil) do
      McptaskRunner::EventStream.end_session
    end
  end

  def test_channel_identifier_is_valid_json
    parsed = JSON.parse(McptaskRunner::EventStream::CHANNEL_IDENTIFIER)
    assert_equal "RunnerSessionChannel", parsed["channel"]
  end

  def test_emit_snapshot_sends_correct_payload_format
    ws = fake_ws
    McptaskRunner::EventStream.instance_variable_set(:@ws, ws)

    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.emit_snapshot({ status: "processing", task_id: 42 })
    end

    assert_equal 1, ws.sent.size
    outer = JSON.parse(ws.sent.first)
    assert_equal "message", outer["command"]
    inner = JSON.parse(outer["data"])
    assert_equal "snapshot", inner["action"]
    assert_equal "test-session-id", inner["session_id"]
    assert_equal "test-machine", inner["machine_id"]
    assert_equal "processing", inner["snapshot"]["status"]
    assert_equal 42, inner["snapshot"]["task_id"]
  end

  def test_throttle_coalesces_rapid_snapshots
    ws = fake_ws
    McptaskRunner::EventStream.instance_variable_set(:@ws, ws)
    # Simulate a very recent emit to trigger throttle
    McptaskRunner::EventStream.instance_variable_set(
      :@last_snapshot_emit,
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
    McptaskRunner::EventStream.instance_variable_set(:@last_emitted_status, "processing")

    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.emit_snapshot({ status: "processing" })
      McptaskRunner::EventStream.emit_snapshot({ status: "processing" })
    end

    assert_equal 0, ws.sent.size, "throttle should suppress rapid same-status emits"
  end

  def test_status_change_bypasses_throttle
    ws = fake_ws
    McptaskRunner::EventStream.instance_variable_set(:@ws, ws)
    McptaskRunner::EventStream.instance_variable_set(
      :@last_snapshot_emit,
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
    McptaskRunner::EventStream.instance_variable_set(:@last_emitted_status, "processing")

    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.emit_snapshot({ status: "waiting" })
    end

    assert_equal 1, ws.sent.size, "status change must bypass throttle"
    inner = JSON.parse(JSON.parse(ws.sent.first)["data"])
    assert_equal "waiting", inner["snapshot"]["status"]
  end

  def test_closed_status_bypasses_throttle
    ws = fake_ws
    McptaskRunner::EventStream.instance_variable_set(:@ws, ws)
    McptaskRunner::EventStream.instance_variable_set(
      :@last_snapshot_emit,
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
    McptaskRunner::EventStream.instance_variable_set(:@last_emitted_status, "closed")

    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.emit_snapshot({ status: "closed" })
    end

    assert_equal 1, ws.sent.size, "closed tombstone must bypass throttle even with same status"
  end

  def test_reconnect_resends_last_snapshot
    last = { status: "processing", task_id: 99 }
    McptaskRunner::EventStream.instance_variable_set(:@last_snapshot, last)

    ws = fake_ws
    McptaskRunner::EventStream.instance_variable_set(:@ws, ws)

    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.send(:handle_message,
        JSON.generate({ "type" => "confirm_subscription" }))
    end

    assert_equal 1, ws.sent.size, "reconnect must re-emit last snapshot"
    inner = JSON.parse(JSON.parse(ws.sent.first)["data"])
    assert_equal 99, inner["snapshot"]["task_id"]
  end

  def test_reconnect_skips_resend_when_no_prior_snapshot
    McptaskRunner::EventStream.instance_variable_set(:@last_snapshot, nil)

    ws = fake_ws
    McptaskRunner::EventStream.instance_variable_set(:@ws, ws)

    with_env("MCPT_RUNNER_CABLE_URL" => "ws://localhost:3000/cable", "MCPTASK_TOKEN" => "abc") do
      McptaskRunner::EventStream.send(:handle_message,
        JSON.generate({ "type" => "confirm_subscription" }))
    end

    assert_equal 0, ws.sent.size
  end

  private

  FakeWs = Struct.new(:sent) do
    def open? = true
    def send(msg) = sent << msg
  end

  def fake_ws
    FakeWs.new([])
  end

  def with_env(vars)
    original = vars.keys.map { |k| [ k, ENV[k] ] }.to_h
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
