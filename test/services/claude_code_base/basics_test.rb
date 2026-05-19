# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseBasicsTest < Minitest::Test
  def test_claude_code_base_cannot_be_instantiated_with_abstract_methods
    base = McptaskRunner::ClaudeCodeBase.new
    assert_raises(NotImplementedError) { base.send(:build_instructions) }
  end

  def test_model_name_is_abstract
    base = McptaskRunner::ClaudeCodeBase.new
    assert_raises(NotImplementedError) { base.send(:model_name) }
  end

  def test_project_relative_id_loaded_from_claude_md
    File.stub :exist?, true do
      File.stub :read, "## mcptask.online\n- project_relative_id=42" do
        base = McptaskRunner::ClaudeCodeBase.new
        project_id = base.send(:project_relative_id)
        assert_equal 42, project_id
      end
    end
  end

  def test_project_relative_id_returns_nil_when_file_not_found
    File.stub :exist?, false do
      base = McptaskRunner::ClaudeCodeBase.new
      project_id = base.send(:project_relative_id)
      assert_nil project_id
    end
  end

  def test_error_result_creates_error_hash
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:error_result, 'Test error message')
    assert_equal 'error', result['status']
    assert_equal 'Test error message', result['message']
  end

  def test_inactivity_timeout_constant_is_defined
    assert_equal 1200, McptaskRunner::ClaudeCodeBase::INACTIVITY_TIMEOUT
  end

  def test_accept_edits_defaults_to_true
    base = McptaskRunner::ClaudeCodeBase.new
    assert base.send(:accept_edits?)
  end

  def test_max_retry_attempts_constant_is_defined
    assert_equal 3, McptaskRunner::ClaudeCodeBase::MAX_RETRY_ATTEMPTS
  end

  def test_retry_wait_seconds_constant_is_defined
    assert_equal 30, McptaskRunner::ClaudeCodeBase::RETRY_WAIT_SECONDS
  end

  def test_heartbeat_interval_constant_is_defined
    assert_equal 120, McptaskRunner::ClaudeCodeBase::HEARTBEAT_INTERVAL
  end

  def test_process_kill_timeout_constant_is_defined
    assert_equal 5, McptaskRunner::ClaudeCodeBase::PROCESS_KILL_TIMEOUT
  end

  def test_stdout_sync_is_enabled
    assert $stdout.sync, 'Expected $stdout.sync to be true'
  end

  def test_initialize_sets_stopping_to_false
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.instance_variable_get(:@state).stopping
  end

  def test_initialize_sets_retry_state
    base = McptaskRunner::ClaudeCodeBase.new
    retry_state = base.instance_variable_get(:@retry_state)
    assert_equal 0, retry_state.count
    assert_equal 0, retry_state.api_overload_count
    refute retry_state.marker_retry_mode
  end

  def test_initialize_sets_api_overload_flag_to_false
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.instance_variable_get(:@state).api_overload
  end

  def test_initialize_sets_context_overflow_flag_to_false
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.instance_variable_get(:@state).context_overflow
  end

  def test_initialize_sets_result_received_to_false
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.instance_variable_get(:@state).result_received
  end

  def test_initialize_sets_inactivity_timeout_to_false
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.instance_variable_get(:@state).inactivity_timeout
  end

  def test_initialize_sets_stream_line_count_to_zero
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal 0, base.instance_variable_get(:@state).stream_line_count
  end

  def test_initialize_sets_child_pid_to_nil
    base = McptaskRunner::ClaudeCodeBase.new
    assert_nil base.instance_variable_get(:@state).child_pid
  end

  def test_initialize_sets_quota_watch_to_nil
    base = McptaskRunner::ClaudeCodeBase.new
    assert_nil base.instance_variable_get(:@quota_watch)
  end

  def test_initialize_sets_quota_exceeded_to_false
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.instance_variable_get(:@state).quota_exceeded
  end

  def test_initialize_sets_stalled_to_nil
    base = McptaskRunner::ClaudeCodeBase.new
    assert_nil base.instance_variable_get(:@state).stalled
  end

  def test_initialize_creates_stall_detector
    base = McptaskRunner::ClaudeCodeBase.new
    assert_kind_of McptaskRunner::StallDetector, base.instance_variable_get(:@stall_detector)
  end

  def test_initialize_has_no_active_tools
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal 0, base.instance_variable_get(:@snapshot_builder).active_tool_count
  end

  def test_release_test_lock_handles_missing_script
    base = McptaskRunner::ClaudeCodeBase.new
    File.stub(:executable?, false) do
      assert_nil base.send(:release_test_lock)
    end
  end
end
