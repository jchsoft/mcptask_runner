# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseStreamingTest < Minitest::Test
  def test_stream_lines_yields_each_line
    base = McptaskRunner::ClaudeCodeBase.new
    io = StringIO.new("line1\nline2\nline3\n")
    lines = []

    base.send(:stream_lines, io) { |line| lines << line.strip }

    assert_equal %w[line1 line2 line3], lines
  end

  def test_stream_lines_breaks_when_result_received
    base = McptaskRunner::ClaudeCodeBase.new
    io = StringIO.new("line1\nline2\nline3\nline4\n")
    lines = []

    base.send(:stream_lines, io) do |line|
      lines << line.strip
      base.instance_variable_get(:@state).result_received = true if line.strip == 'line2'
    end

    assert_equal %w[line1 line2], lines, 'Should stop after result_received is set'
  end

  # Defense-in-depth: terminal flags (context_overflow, stall, quota, etc.) all set
  # @state.stopping. Without breaking on it here, a still-open stdout pipe would keep
  # the reader running indefinitely even after the watchdog has decided to abort.
  def test_stream_lines_breaks_when_stopping
    base = McptaskRunner::ClaudeCodeBase.new
    io = StringIO.new("line1\nline2\nline3\nline4\n")
    lines = []

    base.send(:stream_lines, io) do |line|
      lines << line.strip
      base.instance_variable_get(:@state).stopping = true if line.strip == 'line2'
    end

    assert_equal %w[line1 line2], lines, 'Should stop after stopping flag is set'
  end

  def test_handle_stream_error_returns_early_when_stopping
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).stopping = true

    yielded = false
    base.send(:handle_stream_error, IOError.new('test'), 'stdout') { yielded = true }

    refute yielded, 'Should not yield when stopping'
  end

  def test_handle_stream_error_yields_error_message_when_not_stopping
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).stopping = false

    error_msg = nil
    base.send(:handle_stream_error, IOError.new('stream closed'), 'stdout') { |msg| error_msg = msg }

    assert_match(/stdout stream closed unexpectedly/, error_msg)
    assert_match(/stream closed/, error_msg)
  end

  def test_check_for_result_message_ignores_interim_result_without_marker
    base = McptaskRunner::ClaudeCodeBase.new
    result_line = '{"type": "result", "result": "Tests running in background..."}'

    base.send(:check_for_result_message, result_line)

    refute base.instance_variable_get(:@state).result_received
    refute base.instance_variable_get(:@state).stopping
  end

  def test_check_for_result_message_sets_flag_on_final_result_with_marker
    base = McptaskRunner::ClaudeCodeBase.new
    result_line = '{"type": "result", "result": "{\"TASKRUNNER_RESULT\": true, \"status\": \"success\"}"}'

    base.send(:check_for_result_message, result_line)

    assert base.instance_variable_get(:@state).result_received
    assert base.instance_variable_get(:@state).stopping
  end

  def test_check_for_result_message_ignores_non_result_types
    base = McptaskRunner::ClaudeCodeBase.new
    assistant_line = '{"type": "assistant", "message": "Hello"}'

    base.send(:check_for_result_message, assistant_line)

    refute base.instance_variable_get(:@state).result_received
  end

  def test_check_for_result_message_ignores_invalid_json
    base = McptaskRunner::ClaudeCodeBase.new
    invalid_line = 'This is not JSON at all'

    base.send(:check_for_result_message, invalid_line)

    refute base.instance_variable_get(:@state).result_received
  end

  def test_check_for_result_message_skips_when_already_received
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).result_received = true
    base.instance_variable_get(:@state).stopping = false
    result_line = '{"type": "result", "cost_usd": 0.05}'

    base.send(:check_for_result_message, result_line)

    refute base.instance_variable_get(:@state).stopping
  end

  # Regression: test-start Skill never emits task_notification (Claude Code bug).
  # Heartbeat detects it as hung (600s) → status=pending. finalize_streaming
  # previously returned early (status != "processing"), leaving the session stuck
  # in "pending" with test-start still shown as active in the UI.
  def test_finalize_streaming_clears_orphan_skill_and_emits_finished_when_pending
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.tool_started(tool_id: 'toolu_test_start', name: 'Skill', summary: 'test-start')
    builder.set_status(:pending, error_message: 'Tool Skill pending for 989s')

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snap, **) { emitted << snap }) do
      base.send(:finalize_streaming, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5.0)
    end

    assert_equal 'finished', builder.status, 'pending session must transition to finished'
    assert_empty builder.to_h[:active_actions], 'orphan Skill must be cleared at session end'
    assert_equal 1, emitted.size, 'one final snapshot must be emitted'
    assert_empty emitted.last[:active_actions]
    assert_equal 'finished', emitted.last[:status]
  end

  def test_finalize_streaming_clears_orphan_skill_from_processing_snapshot
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.tool_started(tool_id: 'toolu_test_start', name: 'Skill', summary: 'test-start')

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snap, **) { emitted << snap }) do
      base.send(:finalize_streaming, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5.0)
    end

    assert_equal 'finished', builder.status
    assert_empty emitted.last[:active_actions], 'orphan Skill cleared even from processing state'
  end

  # Regression: StalledError/Timeout::Error/QuotaExceededMidTaskError all propagate out of
  # join_streaming_threads from INSIDE the Open3.popen3 block. finalize_streaming used to be
  # called only AFTER that block, so it was skipped entirely for those three terminations —
  # the RunLog termination stamp went missing for exactly the pathological cases someone opens
  # the file to diagnose.
  def test_execute_with_streaming_finalizes_run_log_even_when_join_streaming_threads_raises
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    fake_wait_thr = Object.new.tap { |o| o.define_singleton_method(:pid) { 4242 } }
    noop_thread = Thread.new { }
    finalize_calls = []
    disable_env_was = ENV.delete(McptaskRunner::EventStream::DISABLE_ENV)

    base.stub(:start_run_log, nil) do
      base.stub(:start_stdout_thread, noop_thread) do
        base.stub(:start_stderr_thread, noop_thread) do
          base.stub(:start_supervised_heartbeat, noop_thread) do
            base.stub(:join_streaming_threads, ->(*) { raise Timeout::Error, 'Claude inactive for 900s' }) do
              base.stub(:finalize_streaming, ->(elapsed) { finalize_calls << elapsed }) do
                popen3_stub = ->(*_args, **_kwargs, &blk) { blk.call(StringIO.new, StringIO.new, StringIO.new, fake_wait_thr) }
                Open3.stub(:popen3, popen3_stub) do
                  assert_raises(Timeout::Error) { base.send(:execute_with_streaming, %w[echo hi]) }
                end
              end
            end
          end
        end
      end
    end

    assert_equal 1, finalize_calls.size, 'finalize_streaming must still run when the popen3 block raises'
  ensure
    ENV[McptaskRunner::EventStream::DISABLE_ENV] = disable_env_was if disable_env_was
  end
end
