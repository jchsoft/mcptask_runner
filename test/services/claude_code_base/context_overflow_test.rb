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

  # Regression (mcptask #11358): the overflow watchdog used to leave the snapshot at "processing",
  # so finalize_streaming read the killed attempt as a clean completion and flipped the web card
  # Processing → Finished. mcptask.online reaped the card 5 min later while handle_context_overflow
  # was already running a fresh restart that kept working for another 20+ minutes.
  def test_check_for_context_overflow_emits_error_snapshot
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snapshot, **_kw) { emitted << snapshot }) do
      base.stub(:kill_process, ->(_pid) { }) do
        base.send(:check_for_context_overflow, '[Claude] Prompt is too long')
      end
    end

    assert_equal 'error', builder.status, 'snapshot status must be :error so finalize_streaming skips :finished override'
    refute_empty emitted, 'must emit at least one snapshot via EventStream'
    assert_equal 'error', emitted.last[:status]
    assert_match(/Context overflow/, emitted.last[:error_message])
  end

  # The killed attempt must stay :error all the way through stream teardown — finalize_streaming
  # only re-flags "processing"/"pending", never a watchdog verdict.
  def test_finalize_streaming_keeps_error_status_after_overflow
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    base.stub(:kill_process, ->(_pid) { }) do
      base.send(:check_for_context_overflow, 'Prompt is too long')
    end

    base.send(:finalize_streaming, Process.clock_gettime(Process::CLOCK_MONOTONIC))

    assert_equal 'error', builder.status, 'finalize_streaming must not resurrect an overflow-killed attempt as :finished'
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

  # First overflow is recoverable: signal a FRESH-session restart (no --continue) and reset the
  # carried-over output buffer so the new attempt re-discovers on-disk work instead of dying.
  def test_handle_context_overflow_first_time_signals_fresh_restart
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, +'bloated overflowing output')
    base.instance_variable_set(:@text_content, +'stale text')

    result = base.send(:handle_context_overflow, Time.now - 3600)

    assert_nil result, 'first overflow must return nil to signal a retry'
    retry_state = base.instance_variable_get(:@retry_state)
    assert_equal 1, retry_state.overflow_restart_count
    assert retry_state.fresh_restart, 'must arm a fresh (no --continue) restart'
    assert_equal 0, retry_state.count, 'must NOT burn a normal retry slot'
    assert_equal '', base.instance_variable_get(:@accumulated_output), 'must reset accumulated output'
    assert_equal '', base.instance_variable_get(:@text_content), 'must reset text content'
  end

  # A re-overflow after the fresh restart means the task genuinely exceeds the limit → terminal.
  def test_handle_context_overflow_after_restart_returns_terminal_error
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).overflow_restart_count = McptaskRunner::Concerns::RetryHandling::MAX_OVERFLOW_RESTARTS

    result = base.send(:handle_context_overflow, Time.now - 3600)

    assert_equal 'error', result['status']
    assert_equal 'context_overflow', result['reason']
    assert_match(/Context overflow/, result['message'])
    assert_match(/fresh restart also overflowed/, result['message'])
    assert_equal 0, base.instance_variable_get(:@retry_state).count,
                 'Must NOT increment the normal retry counter on a context-overflow terminal'
  end

  # A fresh restart must drop --continue even though count>0 would normally request it, and the
  # flag is consumed (one attempt only) so a later non-overflow failure resumes normally.
  def test_attempt_execution_fresh_restart_omits_continue_and_consumes_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }
    base.instance_variable_get(:@retry_state).count = 1 # would normally force --continue
    base.instance_variable_get(:@retry_state).fresh_restart = true

    base.instance_variable_set(:@accumulated_output, +'')
    captured = nil
    capture = ->(_base, _instructions, continue_session: false) { captured = continue_session; [] }
    base.stub(:build_command, capture) do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, { 'status' => 'success' }) do
          base.instance_variable_get(:@state).result_received = true
          base.send(:attempt_execution, Time.now)
        end
      end
    end

    refute captured, 'fresh restart must NOT pass --continue'
    refute base.instance_variable_get(:@retry_state).fresh_restart, 'fresh_restart flag must be consumed after one attempt'
  end

  # A fresh restart must hand the new (empty-context) session the last few actions of the dead
  # session plus a work-lean nudge, so it doesn't blindly re-explore and re-overflow.
  def test_attempt_execution_fresh_restart_prepends_recent_actions_handoff
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'FULL WORKFLOW' }
    base.instance_variable_get(:@retry_state).fresh_restart = true

    sb = base.instance_variable_get(:@snapshot_builder)
    sb.tool_started(tool_id: 't1', name: 'Bash', summary: 'find page_controller')
    sb.tool_finished(tool_id: 't1')

    base.instance_variable_set(:@accumulated_output, +'')
    captured = nil
    capture = ->(_base, instructions, continue_session: false) { captured = instructions; [] }
    base.stub(:build_command, capture) do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, { 'status' => 'success' }) do
          base.instance_variable_get(:@state).result_received = true
          base.send(:attempt_execution, Time.now)
        end
      end
    end

    assert_match(/ran out of context/, captured, 'fresh restart must include the overflow handoff preamble')
    assert_includes captured, 'Bash: find page_controller', 'must list the dead session\'s recent actions'
    assert_includes captured, 'FULL WORKFLOW', 'must still include the full fresh instructions'
  end

  # No recent actions captured (overflow before any tool ran) → no preamble, instructions untouched.
  def test_attempt_execution_fresh_restart_no_preamble_without_recent_actions
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'FULL WORKFLOW' }
    base.instance_variable_get(:@retry_state).fresh_restart = true

    base.instance_variable_set(:@accumulated_output, +'')
    captured = nil
    capture = ->(_base, instructions, continue_session: false) { captured = instructions; [] }
    base.stub(:build_command, capture) do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, { 'status' => 'success' }) do
          base.instance_variable_get(:@state).result_received = true
          base.send(:attempt_execution, Time.now)
        end
      end
    end

    assert_equal 'FULL WORKFLOW', captured, 'empty handoff must leave instructions byte-for-byte unchanged'
  end

  # A non-fresh --continue retry (count>0) must send the short continuation prompt, NOT the full
  # build_instructions — the resumed session already carries the full workflow in context.
  def test_attempt_execution_continue_retry_uses_continuation_prompt
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'FULL WORKFLOW INSTRUCTIONS' }
    base.instance_variable_get(:@retry_state).count = 1 # non-fresh retry → --continue

    base.instance_variable_set(:@accumulated_output, +'')
    captured_continue = nil
    captured_instructions = nil
    capture = lambda do |_base, instructions, continue_session: false|
      captured_instructions = instructions
      captured_continue = continue_session
      []
    end
    base.stub(:build_command, capture) do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, { 'status' => 'success' }) do
          base.instance_variable_get(:@state).result_received = true
          base.send(:attempt_execution, Time.now)
        end
      end
    end

    assert captured_continue, 'non-fresh retry (count>0) must pass --continue'
    refute_includes captured_instructions, 'FULL WORKFLOW INSTRUCTIONS',
                    'continue retry must send the short continuation prompt, not full instructions'
    assert_includes captured_instructions, 'TASKRUNNER_RESULT'
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

  def test_attempt_execution_first_overflow_signals_fresh_restart
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
          assert_nil result, 'first overflow signals a fresh restart, not a terminal error'
          assert base.instance_variable_get(:@retry_state).fresh_restart
        end
      end
    end
  end

  def test_attempt_execution_emits_context_overflow_terminal_error_after_restart_exhausted
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }
    base.instance_variable_get(:@retry_state).overflow_restart_count = McptaskRunner::Concerns::RetryHandling::MAX_OVERFLOW_RESTARTS

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
