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
end
