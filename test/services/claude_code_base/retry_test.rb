# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseRetryTest < Minitest::Test
  def test_stream_closed_error_exists
    assert_kind_of Class, McptaskRunner::StreamClosedError
    assert McptaskRunner::StreamClosedError < StandardError
  end

  def test_stream_closed_error_can_be_raised_with_message
    error = McptaskRunner::StreamClosedError.new('test error message')
    assert_equal 'test error message', error.message
  end

  def test_missing_marker_error_exists
    assert_kind_of Class, McptaskRunner::MissingMarkerError
    assert McptaskRunner::MissingMarkerError < StandardError
  end

  def test_missing_marker_error_can_be_raised_with_message
    error = McptaskRunner::MissingMarkerError.new('marker not found')
    assert_equal 'marker not found', error.message
  end

  def test_handle_recoverable_error_returns_nil_for_retry
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 0
    start_time = Time.now

    result = base.send(:handle_recoverable_error, 'Timeout', start_time)

    assert_nil result, 'Should return nil to signal retry'
  end

  def test_handle_recoverable_error_returns_error_when_max_retries_reached
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 2 # MAX_RETRY_ATTEMPTS - 1
    start_time = Time.now

    result = base.send(:handle_recoverable_error, 'Timeout', start_time)

    assert_equal 'error', result['status']
    assert_match(/retries exhausted/, result['message'])
  end

  def test_handle_marker_retry_returns_nil_for_retry
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 0
    start_time = Time.now

    result = base.send(:handle_marker_retry, start_time)

    assert_nil result, 'Should return nil to signal retry'
  end

  def test_handle_marker_retry_sets_marker_retry_mode
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 0
    start_time = Time.now

    base.send(:handle_marker_retry, start_time)

    assert base.instance_variable_get(:@retry_state).marker_retry_mode, 'Should set marker_retry_mode to true'
  end

  def test_handle_marker_retry_returns_error_when_max_retries_reached
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 2 # MAX_RETRY_ATTEMPTS - 1
    start_time = Time.now

    result = base.send(:handle_marker_retry, start_time)

    assert_equal 'error', result['status']
    assert_match(/Missing TASKRUNNER_RESULT/, result['message'])
    assert_match(/retries exhausted/, result['message'])
  end

  def test_build_marker_retry_instructions_contains_retry_guidance
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:build_instructions) { 'Original workflow instructions here' }

    instructions = base.send(:build_marker_retry_instructions)

    assert_includes instructions, 'previous session was interrupted'
    assert_includes instructions, 'Check what you already completed'
    assert_includes instructions, 'git status'
    assert_includes instructions, 'Continue from where you left off'
    assert_includes instructions, 'Complete ALL remaining steps'
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'Do NOT just output the marker'
  end

  def test_build_marker_retry_instructions_includes_original_instructions
    base = McptaskRunner::ClaudeCodeBase.new
    original_instructions = 'Step 1: Do this\nStep 2: Do that\nTASKRUNNER_RESULT: {"status": "success"}'
    base.define_singleton_method(:build_instructions) { original_instructions }

    instructions = base.send(:build_marker_retry_instructions)

    assert_includes instructions, 'ORIGINAL WORKFLOW'
    assert_includes instructions, 'Step 1: Do this'
    assert_includes instructions, 'Step 2: Do that'
  end
end
