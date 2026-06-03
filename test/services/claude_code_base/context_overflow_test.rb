# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseContextOverflowTest < Minitest::Test
  def test_check_for_context_overflow_sets_flag_on_prompt_too_long
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_for_context_overflow, '[Claude] Prompt is too long')

    assert base.instance_variable_get(:@state).context_overflow, 'Should set flag on "Prompt is too long"'
    assert base.instance_variable_get(:@state).stopping, 'Should mark stopping to treat stream closure as expected'
  end

  # Regression: context overflow used to set stopping=true but leave subprocess alive.
  # Heartbeat exits on stopping=true → no watchdog. Orphan child processes (MCP servers,
  # hooks) inherited from Claude kept the stdout pipe open after Claude died, so
  # stdout_thread.join blocked forever. Process hung indefinitely with no heartbeats.
  def test_check_for_context_overflow_kills_subprocess_to_unblock_stdout_thread
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    killed_pid = nil
    base.stub(:kill_process, ->(pid) { killed_pid = pid }) do
      base.send(:check_for_context_overflow, '[Claude] Prompt is too long')
    end

    assert_equal 12_345, killed_pid, 'must SIGTERM subprocess so stdout pipe closes'
  end

  def test_check_for_context_overflow_no_kill_when_pattern_absent
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    killed = false
    base.stub(:kill_process, ->(_pid) { killed = true }) do
      base.send(:check_for_context_overflow, '{"type":"assistant"}')
    end

    refute killed, 'must not kill on unrelated lines'
  end

  def test_check_for_context_overflow_kills_only_once_even_with_repeated_lines
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345

    kill_count = 0
    base.stub(:kill_process, ->(_pid) { kill_count += 1 }) do
      base.send(:check_for_context_overflow, 'Prompt is too long')
      base.send(:check_for_context_overflow, 'Prompt is too long again')
    end

    assert_equal 1, kill_count, 'second invocation must short-circuit on context_overflow flag'
  end

  def test_check_for_context_overflow_matches_context_length_exceeded
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_for_context_overflow, '{"error":{"type":"context_length_exceeded"}}')

    assert base.instance_variable_get(:@state).context_overflow
  end

  def test_check_for_context_overflow_does_not_set_flag_on_normal_output
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_for_context_overflow, '{"type":"assistant","message":"Hello"}')

    refute base.instance_variable_get(:@state).context_overflow
  end

  def test_context_overflow_detected_via_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '')
    base.instance_variable_get(:@state).context_overflow = true

    assert base.send(:context_overflow_detected?), 'Should detect via flag even with empty accumulated_output'
  end

  # Regression: a healthy 30K-token session was killed because the agent ran
  # `Read claude_code_base.rb`, whose line-29 comment documents the phrase
  # ("Prompt is too long"). The successful tool_result echoing that file content
  # streamed back and the old naive `line.include?` / @accumulated_output substring
  # scan mistook it for a real overflow. A successful tool_result must NOT trip it.
  def test_check_for_context_overflow_ignores_successful_tool_result_echoing_phrase
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345
    echoed = JSON.generate(
      'type' => 'user',
      'message' => { 'content' => [
        { 'type' => 'tool_result', 'tool_use_id' => 'x', 'is_error' => false,
          'content' => '29: # Raised when context exceeds limit ("Prompt is too long").' }
      ] }
    )

    killed = false
    base.stub(:kill_process, ->(_pid) { killed = true }) do
      base.send(:check_for_context_overflow, echoed)
    end

    refute base.instance_variable_get(:@state).context_overflow,
           'echoed file content must not flag overflow'
    refute killed, 'must not kill a healthy session over echoed file content'
  end

  # Regression: a healthy ~88K-token self-hosted run was killed when the agent ran
  # `ruby bin/ci`, which exited 1 (failed) → tool_result is_error:true, AND whose output
  # quoted "Prompt is too long" because the suite runs context_overflow_test.rb (this very
  # file). The old nested-tool_result branch matched is_error+phrase and self-detonated.
  # A tool_result is tool OUTPUT — never the session's own API overflow — so an error-flagged
  # tool_result echoing the phrase must NOT trip the kill.
  def test_check_for_context_overflow_ignores_failed_command_tool_result_echoing_phrase
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345
    failed_ci = JSON.generate(
      'type' => 'user',
      'message' => { 'content' => [
        { 'type' => 'tool_result', 'is_error' => true,
          'content' => "Exit code 1\nCI Runner\ncontext_overflow_test.rb\n" \
                        "❌ [ClaudeCodeBase] Context overflow detected ('Prompt is too long')\n" }
      ] }
    )

    killed = false
    base.stub(:kill_process, ->(_pid) { killed = true }) do
      base.send(:check_for_context_overflow, failed_ci)
    end

    refute base.instance_variable_get(:@state).context_overflow,
           'a failed command echoing the phrase must not flag overflow'
    refute killed, 'must not kill a healthy session over a failed bin/ci tool_result'
  end

  # A genuine API-level overflow arrives at the TOP LEVEL of a result event
  # (is_error:true), not nested in a tool_result — that path must still trip.
  def test_check_for_context_overflow_fires_on_top_level_error_result_event
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = 12_345
    err = JSON.generate(
      'type' => 'result', 'subtype' => 'error_during_execution',
      'is_error' => true, 'result' => 'Prompt is too long'
    )

    base.stub(:kill_process, ->(_pid) {}) do
      base.send(:check_for_context_overflow, err)
    end

    assert base.instance_variable_get(:@state).context_overflow
  end

  # Detection is now flag-only (set by the JSON-aware streaming detector). The
  # @accumulated_output substring scan was the false-positive vector and is gone.
  def test_context_overflow_detected_is_flag_only_not_accumulated_substring
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, 'some output Prompt is too long some more')

    refute base.send(:context_overflow_detected?),
           'accumulated_output substring must NOT detect — only the @state flag may'
  end

  def test_handle_context_overflow_returns_terminal_error_no_retry
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:handle_context_overflow, Time.now - 3600)

    assert_equal 'error', result['status']
    assert_equal 'context_overflow', result['reason']
    assert_match(/Context overflow/, result['message'])
    assert_match(/cannot resume/, result['message'])
    assert_equal 0, base.instance_variable_get(:@retry_state).count,
                 'Must NOT increment retry counter — session is dead, --continue cannot recover'
  end

  # Bug fix: TASKRUNNER_RESULT must win over context_overflow / api_overload patterns that
  # appeared earlier in the stream (e.g., a sub-agent hit overflow but main task completed).
  # Without this, a successful task gets reclassified as terminal context_overflow error.
  def test_attempt_execution_trusts_result_received_over_context_overflow_pattern
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }

    success_result = { 'status' => 'success', 'pr_number' => 1158, 'hours' => { 'task_worked' => 0.5 } }
    base.stub(:resolve_claude_path, '/fake/claude') do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, success_result) do
          base.instance_variable_set(:@accumulated_output, +'noise Prompt is too long noise')
          base.instance_variable_get(:@state).result_received = true

          result = base.send(:attempt_execution, Time.now)

          assert_equal 'success', result['status']
          assert_equal 1158, result['pr_number']
        end
      end
    end
  end

  def test_attempt_execution_emits_context_overflow_terminal_error_when_no_result_received
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }

    error_result = { 'status' => 'error', 'message' => 'No TASKRUNNER_RESULT found in output' }
    base.stub(:resolve_claude_path, '/fake/claude') do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, error_result) do
          base.instance_variable_set(:@accumulated_output, +'')
          base.instance_variable_get(:@state).result_received = false
          base.instance_variable_get(:@state).context_overflow = true # set by JSON-aware streaming detector

          result = base.send(:attempt_execution, Time.now)
          assert_equal 'error', result['status']
          assert_equal 'context_overflow', result['reason']
        end
      end
    end
  end

  def test_attempt_execution_triggers_marker_retry_when_parse_failed_without_result_received
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }

    error_result = { 'status' => 'error', 'message' => 'No TASKRUNNER_RESULT found in output' }
    base.stub(:resolve_claude_path, '/fake/claude') do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, error_result) do
          base.instance_variable_set(:@accumulated_output, +'no marker no overflow')
          base.instance_variable_get(:@state).result_received = false

          result = base.send(:attempt_execution, Time.now)
          assert_nil result, 'Should return nil to signal retry attempt'
          assert base.instance_variable_get(:@retry_state).marker_retry_mode
        end
      end
    end
  end
end
