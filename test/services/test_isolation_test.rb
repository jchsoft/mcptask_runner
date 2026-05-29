# frozen_string_literal: true

require 'test_helper'

# Regression for piece #10465: when tests ran on a developer machine that had
# WORKVECTOR_KAMR_TOKEN exported in the shell, EventStream resolved a real token,
# opened a WebSocket to mcptask.online, and emit_snapshot calls created visible
# "runner" cards on the production web UI. ENV.delete in test_helper was the only
# defense and proved insufficient in practice.
#
# The hard fix: MCPTASK_RUNNER_DISABLE env flag, set in test_helper, that forces
# every outbound mcptask.online code path to refuse real network I/O.
class TestIsolationTest < Minitest::Test
  DISABLE_ENV = McptaskRunner::EventStream::DISABLE_ENV

  def test_disable_env_is_set_by_test_helper
    refute_empty ENV[DISABLE_ENV].to_s, "#{DISABLE_ENV} must be set by test_helper"
  end

  def test_event_stream_disabled_even_when_token_and_cable_url_resolve
    McptaskRunner::EventStream.instance_variable_set(:@mcp_json, nil)
    ENV["WORKVECTOR_KAMR_TOKEN"] = "leaked-token-from-dev-shell"
    ENV["MCPT_RUNNER_CABLE_URL"] = "wss://mcptask.online/cable"

    refute McptaskRunner::EventStream.enabled?,
           "EventStream must stay disabled in tests even when token + URL resolve"
  ensure
    ENV.delete("WORKVECTOR_KAMR_TOKEN")
    ENV.delete("MCPT_RUNNER_CABLE_URL")
  end

  def test_event_stream_emit_snapshot_is_noop_in_tests
    McptaskRunner::EventStream.instance_variable_set(:@mcp_json, nil)
    sent = []
    fake_ws = Class.new do
      define_method(:open?) { true }
      define_method(:send) { |msg| sent << msg }
    end.new
    McptaskRunner::EventStream.instance_variable_set(:@ws, fake_ws)
    ENV["WORKVECTOR_KAMR_TOKEN"] = "leaked-token"

    McptaskRunner::EventStream.emit_snapshot({ status: "processing", task_id: 123 })

    assert_empty sent, "emit_snapshot must not send WebSocket frames when DISABLE_ENV is set"
  ensure
    ENV.delete("WORKVECTOR_KAMR_TOKEN")
    McptaskRunner::EventStream.instance_variable_set(:@ws, nil)
  end

  def test_time_status_client_refuses_real_http_in_tests
    ENV["WORKVECTOR_KAMR_TOKEN"] = "leaked-token"
    ENV["MCPTASK_BASE_URL"] = "https://mcptask.online"

    error = assert_raises(McptaskRunner::TimeStatusClient::Error) { McptaskRunner::TimeStatusClient.fetch }
    assert_match(/#{DISABLE_ENV}/, error.message)
  ensure
    ENV.delete("WORKVECTOR_KAMR_TOKEN")
    ENV.delete("MCPTASK_BASE_URL")
  end

  def test_claude_code_base_refuses_to_spawn_in_tests
    base = McptaskRunner::ClaudeCodeBase.new

    error = assert_raises(RuntimeError) { base.send(:execute_with_streaming, %w[echo hi]) }
    assert_match(/Refusing to spawn/, error.message)
    assert_match(/#{DISABLE_ENV}/, error.message)
  end
end
