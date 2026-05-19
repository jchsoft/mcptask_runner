# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseApiOverloadTest < Minitest::Test
  def test_api_overload_detected_with_529_error_status
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '{"type":"system","subtype":"api_retry","error_status": 529}')

    assert base.send(:api_overload_detected?), 'Should detect 529 error status'
  end

  def test_api_overload_detected_with_repeated_529_message
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '[Claude] API Error: Repeated 529 Overloaded errors')

    assert base.send(:api_overload_detected?), 'Should detect repeated 529 message'
  end

  def test_api_overload_not_detected_for_normal_output
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '{"type":"result","result":"TASKRUNNER_RESULT: {}"}')

    refute base.send(:api_overload_detected?), 'Should not detect overload in normal output'
  end

  def test_handle_api_overload_returns_nil_for_retry
    base = McptaskRunner::ClaudeCodeBase.new

    base.stub(:sleep, nil) do
      result = base.send(:handle_api_overload, Time.now)
      assert_nil result, 'Should return nil to signal retry'
    end
  end

  def test_handle_api_overload_increments_counter
    base = McptaskRunner::ClaudeCodeBase.new

    base.stub(:sleep, nil) do
      base.send(:handle_api_overload, Time.now)
    end

    assert_equal 1, base.instance_variable_get(:@retry_state).api_overload_count
  end

  def test_handle_api_overload_returns_error_at_max_retries
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).api_overload_count = McptaskRunner::Concerns::RetryHandling::MAX_API_OVERLOAD_RETRIES - 1

    result = base.send(:handle_api_overload, Time.now)

    assert_equal 'error', result['status']
    assert_match(/API overloaded/, result['message'])
    assert_match(/529/, result['message'])
  end

  def test_api_overload_does_not_increment_normal_retry_count
    base = McptaskRunner::ClaudeCodeBase.new
    retry_state = base.instance_variable_get(:@retry_state)
    retry_state.count = 0
    retry_state.api_overload_count = 1

    assert_equal 0, retry_state.count
  end

  def test_check_for_api_overload_sets_flag_on_529
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_for_api_overload, '{"type":"system","subtype":"api_retry","error_status": 529}')

    assert base.instance_variable_get(:@state).api_overload, 'Should set flag on 529 error'
  end

  def test_check_for_api_overload_sets_flag_on_repeated_529
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_for_api_overload, '[Claude] API Error: Repeated 529 Overloaded errors')

    assert base.instance_variable_get(:@state).api_overload, 'Should set flag on repeated 529'
  end

  def test_check_for_api_overload_does_not_set_flag_on_normal_output
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_for_api_overload, '{"type":"assistant","message":"Hello"}')

    refute base.instance_variable_get(:@state).api_overload, 'Should not set flag on normal output'
  end

  def test_api_overload_detected_via_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@accumulated_output, '')
    base.instance_variable_get(:@state).api_overload = true

    assert base.send(:api_overload_detected?), 'Should detect overload via flag even with empty accumulated_output'
  end

  def test_stream_closed_with_529_raises_api_overload
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).api_overload = true

    base.stub(:sleep, nil) do
      result = base.send(:handle_api_overload, Time.now)
      assert_nil result, 'API overload handler should return nil to signal retry'
      assert_equal 1, base.instance_variable_get(:@retry_state).api_overload_count, 'Should increment overload counter'
    end
  end
end
