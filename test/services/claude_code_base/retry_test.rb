# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseRetryTest < Minitest::Test
  # Named (not anonymous) so self.class.name is non-nil in ClaudeCodeBase#initialize.
  class StubAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
    def result_json_fields = '"status": "success", "pr_number": N'
  end

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

  def test_build_continuation_instructions_contains_retry_guidance
    base = McptaskRunner::ClaudeCodeBase.new

    instructions = base.send(:build_continuation_instructions)

    assert_includes instructions, 'previous session was interrupted'
    assert_includes instructions, 'Check what you already completed'
    assert_includes instructions, 'git status'
    assert_includes instructions, 'Continue from where you left off'
    assert_includes instructions, 'Complete ALL remaining steps'
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'Do NOT just output the marker'
  end

  # The whole point of the continuation prompt: --continue already replays the full workflow into
  # context, so it must NOT re-embed build_instructions (that would duplicate the done steps).
  def test_build_continuation_instructions_omits_full_workflow
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:build_instructions) { "Step 1: Do this\nStep 2: Do that\n" * 50 }

    instructions = base.send(:build_continuation_instructions)

    refute_includes instructions, 'Step 1: Do this', 'continuation must NOT re-embed the full workflow'
    refute_includes instructions, 'ORIGINAL WORKFLOW'
    assert_operator instructions.length, :<, base.send(:build_instructions).length,
                    'continuation must be shorter than full instructions'
    assert_includes instructions, 'TASKRUNNER_RESULT'
  end

  def test_continuation_result_contract_default_is_generic_reference
    contract = McptaskRunner::ClaudeCodeBase.new.send(:continuation_result_contract)

    assert_includes contract, 'TASKRUNNER_RESULT'
    assert_includes contract, 'specified earlier'
  end

  # auto_squash overrides the contract to reproduce the exact result-format block so a resumed
  # session can't forget the marker.
  def test_autosquash_continuation_contract_reproduces_result_format
    contract = StubAutoSquash.new.send(:continuation_result_contract)

    assert_includes contract, 'TASKRUNNER_RESULT'
    assert_includes contract, '"status": "success"'
    assert_includes contract, '```json'
  end
end
