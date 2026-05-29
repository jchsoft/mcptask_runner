# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseToolNotEnabledTest < Minitest::Test
  MARKER = 'exists but is not enabled in this context'

  # Genuine MCP-disabled failure: an is_error tool_result emitted by the Claude CLI.
  def self.error_line(content = "<tool_use_error>Error: ReadMcpResourceTool #{MARKER}.</tool_use_error>")
    JSON.generate(type: 'user',
                  message: { content: [{ type: 'tool_result', tool_use_id: 'toolu_x', is_error: true, content: content }] })
  end

  # Successful tool_result whose content merely echoes the marker — e.g. a Grep/Read over a
  # file (this very test) or a log quoting the phrase. Must NOT trip the watchdog.
  def self.echo_line
    JSON.generate(type: 'user',
                  message: { content: [{ type: 'tool_result', tool_use_id: 'toolu_x', is_error: false,
                                         content: "test/services/claude_code_base/tool_not_enabled_test.rb:10: '...#{MARKER}...'" }] })
  end

  def test_check_for_tool_not_enabled_sets_flag_on_mcp_disabled_error
    base = McptaskRunner::ClaudeCodeBase.new
    base.stub(:kill_process, ->(_pid) { }) do
      base.send(:check_for_tool_not_enabled, self.class.error_line)
    end

    assert base.instance_variable_get(:@state).tool_not_enabled, 'Should set flag on MCP-disabled error'
    assert base.instance_variable_get(:@state).stopping, 'Should mark stopping to treat stream closure as expected'
  end

  def test_check_for_tool_not_enabled_kills_subprocess
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    killed_pid = nil
    base.stub(:kill_process, ->(pid) { killed_pid = pid }) do
      base.send(:check_for_tool_not_enabled, self.class.error_line)
    end

    assert_equal 12_345, killed_pid, 'must SIGTERM subprocess so stdout pipe closes'
  end

  def test_check_for_tool_not_enabled_emits_error_snapshot
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snapshot, **_kw) { emitted << snapshot }) do
      base.stub(:kill_process, ->(_pid) { }) do
        base.send(:check_for_tool_not_enabled, self.class.error_line)
      end
    end

    assert_equal 'error', builder.status, 'snapshot status must be :error so finalize_streaming skips :finished override'
    refute_empty emitted, 'must emit at least one snapshot via EventStream'
    assert_equal 'error', emitted.last[:status]
    assert_match(/MCP server disconnected/, emitted.last[:error_message])
  end

  def test_check_for_tool_not_enabled_no_kill_when_pattern_absent
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    killed = false
    base.stub(:kill_process, ->(_pid) { killed = true }) do
      base.send(:check_for_tool_not_enabled, '{"type":"assistant"}')
    end

    refute killed, 'must not kill on unrelated lines'
  end

  # Regression: an audit Grep matching the fixture string in a *successful* tool_result
  # once killed a healthy session. A non-error tool_result echoing the marker must NOT trip.
  def test_check_for_tool_not_enabled_ignores_successful_result_echoing_marker
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    killed = false
    base.stub(:kill_process, ->(_pid) { killed = true }) do
      base.send(:check_for_tool_not_enabled, self.class.echo_line)
    end

    refute killed, 'must not kill when a successful (is_error:false) tool_result merely quotes the marker'
    refute base.instance_variable_get(:@state).tool_not_enabled, 'flag must stay false on echoed marker'
  end

  def test_check_for_tool_not_enabled_kills_only_once_with_repeated_lines
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    kill_count = 0
    base.stub(:kill_process, ->(_pid) { kill_count += 1 }) do
      base.send(:check_for_tool_not_enabled, self.class.error_line)
      base.send(:check_for_tool_not_enabled, self.class.error_line)
    end

    assert_equal 1, kill_count, 'second invocation must short-circuit on tool_not_enabled flag'
  end

  def test_tool_not_enabled_detected_via_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '')
    base.instance_variable_get(:@state).tool_not_enabled = true

    assert base.send(:tool_not_enabled_detected?), 'Should detect via flag even with empty accumulated_output'
  end

  # Backstop must be flag-only: a bare accumulated_output substring is the false-positive
  # vector (any Grep/Read echoing the marker), so it must NOT count as detected on its own.
  def test_tool_not_enabled_not_detected_from_accumulated_output_substring
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, 'some output exists but is not enabled in this context more')

    refute base.send(:tool_not_enabled_detected?)
  end

  def test_handle_tool_not_enabled_returns_terminal_error_no_retry
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:handle_tool_not_enabled, Time.now - 1800)

    assert_equal 'error', result['status']
    assert_equal 'tool_not_enabled', result['reason']
    assert_match(/MCP tool not enabled/, result['message'])
    assert_match(/cannot recover/, result['message'])
    assert_equal 0, base.instance_variable_get(:@retry_state).count,
                 'Must NOT increment retry counter — MCP server cannot reattach mid-session'
  end

  def test_attempt_execution_emits_tool_not_enabled_terminal_error
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }

    error_result = { 'status' => 'error', 'message' => 'No TASKRUNNER_RESULT found in output' }
    base.stub(:resolve_claude_path, '/fake/claude') do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, error_result) do
          base.instance_variable_set(:@accumulated_output, +'')
          base.instance_variable_get(:@state).tool_not_enabled = true
          base.instance_variable_get(:@state).result_received = false

          result = base.send(:attempt_execution, Time.now)
          assert_equal 'error', result['status']
          assert_equal 'tool_not_enabled', result['reason']
        end
      end
    end
  end

  # TASKRUNNER_RESULT must win over tool_not_enabled when Claude actually finished — e.g.
  # a sub-agent hit "not enabled" but main task completed via fallback. Mirrors the
  # context_overflow precedence test.
  def test_attempt_execution_trusts_result_received_over_tool_not_enabled_pattern
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }

    success_result = { 'status' => 'success', 'pr_number' => 9001, 'hours' => { 'task_worked' => 0.5 } }
    base.stub(:resolve_claude_path, '/fake/claude') do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, success_result) do
          base.instance_variable_set(:@accumulated_output, +'')
          base.instance_variable_get(:@state).tool_not_enabled = true
          base.instance_variable_get(:@state).result_received = true

          result = base.send(:attempt_execution, Time.now)

          assert_equal 'success', result['status']
          assert_equal 9001, result['pr_number']
        end
      end
    end
  end
end
