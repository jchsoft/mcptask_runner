# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseToolNotEnabledTest < Minitest::Test
  def test_check_for_tool_not_enabled_sets_flag_on_mcp_disabled_error
    base = McptaskRunner::ClaudeCodeBase.new
    base.stub(:kill_process, ->(_pid) {}) do
      base.send(:check_for_tool_not_enabled,
                '<tool_use_error>Error: ReadMcpResourceTool exists but is not enabled in this context.</tool_use_error>')
    end

    assert base.instance_variable_get(:@state).tool_not_enabled, 'Should set flag on MCP-disabled error'
    assert base.instance_variable_get(:@state).stopping, 'Should mark stopping to treat stream closure as expected'
  end

  def test_check_for_tool_not_enabled_kills_subprocess
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    killed_pid = nil
    base.stub(:kill_process, ->(pid) { killed_pid = pid }) do
      base.send(:check_for_tool_not_enabled, 'exists but is not enabled in this context')
    end

    assert_equal 12_345, killed_pid, 'must SIGTERM subprocess so stdout pipe closes'
  end

  def test_check_for_tool_not_enabled_emits_error_snapshot
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snapshot, **_kw) { emitted << snapshot }) do
      base.stub(:kill_process, ->(_pid) {}) do
        base.send(:check_for_tool_not_enabled, 'exists but is not enabled in this context')
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

  def test_check_for_tool_not_enabled_kills_only_once_with_repeated_lines
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    kill_count = 0
    base.stub(:kill_process, ->(_pid) { kill_count += 1 }) do
      base.send(:check_for_tool_not_enabled, 'exists but is not enabled in this context')
      base.send(:check_for_tool_not_enabled, 'exists but is not enabled in this context again')
    end

    assert_equal 1, kill_count, 'second invocation must short-circuit on tool_not_enabled flag'
  end

  def test_tool_not_enabled_detected_via_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '')
    base.instance_variable_get(:@state).tool_not_enabled = true

    assert base.send(:tool_not_enabled_detected?), 'Should detect via flag even with empty accumulated_output'
  end

  def test_tool_not_enabled_detected_via_accumulated_output
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, 'some output exists but is not enabled in this context more')

    assert base.send(:tool_not_enabled_detected?)
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
          base.instance_variable_set(:@accumulated_output, +'tool exists but is not enabled in this context here')
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
          base.instance_variable_set(:@accumulated_output, +'noise exists but is not enabled in this context noise')
          base.instance_variable_get(:@state).result_received = true

          result = base.send(:attempt_execution, Time.now)

          assert_equal 'success', result['status']
          assert_equal 9001, result['pr_number']
        end
      end
    end
  end
end
