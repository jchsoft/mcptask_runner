# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseStallTest < Minitest::Test
  def test_stalled_error_exists
    assert_kind_of Class, McptaskRunner::StalledError
    assert McptaskRunner::StalledError < StandardError
  end

  def test_stalled_error_carries_stall_struct
    stall = McptaskRunner::StallDetector::Stall.new(reason: :edit_failures, signature: 'sig', count: 3)
    error = McptaskRunner::StalledError.new(stall)

    assert_equal stall, error.stall
    assert_match(/edit_failures/, error.message)
    assert_match(/sig/, error.message)
  end

  def test_reset_streaming_state_clears_stalled_flag_and_replaces_detector
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).stalled = :something
    old_detector = base.instance_variable_get(:@stall_detector)

    base.send(:reset_streaming_state)

    assert_nil base.instance_variable_get(:@state).stalled
    refute_same old_detector, base.instance_variable_get(:@stall_detector),
                'Detector must be recreated so accumulated state from prior attempt is dropped'
  end

  def test_check_stall_sets_stalled_and_stops
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).child_pid = nil # nil PID → kill_process is a no-op
    base.instance_variable_get(:@snapshot_builder).set_status(:triage)
    base.instance_variable_get(:@snapshot_builder).set_status(:processing)
    stall = McptaskRunner::StallDetector::Stall.new(reason: :edit_failures, signature: 'sig', count: 3)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) { base.send(:check_stall, stall) }

    assert_equal stall, base.instance_variable_get(:@state).stalled
    assert base.instance_variable_get(:@state).stopping
  end

  def test_check_stall_ignores_nil
    base = McptaskRunner::ClaudeCodeBase.new
    base.send(:check_stall, nil)
    assert_nil base.instance_variable_get(:@state).stalled
    refute base.instance_variable_get(:@state).stopping
  end

  def test_check_stall_emits_snapshot_with_stalled_status
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@snapshot_builder).set_status(:triage)
    base.instance_variable_get(:@snapshot_builder).set_status(:processing)
    stall = McptaskRunner::StallDetector::Stall.new(reason: :edit_failures, signature: 'sig', count: 3, detail: nil)
    emitted_snapshots = []

    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snapshot, force: false) { emitted_snapshots << snapshot }) do
      base.send(:check_stall, stall)
    end

    assert_equal 1, emitted_snapshots.size
    assert_equal 'stalled', emitted_snapshots.first[:status]
    assert_match(/edit_failures/, emitted_snapshots.first[:error_message])
    assert_match(/sig/, emitted_snapshots.first[:error_message])
  end

  def test_check_stall_does_not_overwrite_first_stall
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@snapshot_builder).set_status(:triage)
    base.instance_variable_get(:@snapshot_builder).set_status(:processing)
    first = McptaskRunner::StallDetector::Stall.new(reason: :edit_failures, signature: 'a', count: 3)
    second = McptaskRunner::StallDetector::Stall.new(reason: :loop_signature, signature: 'b', count: 4)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      base.send(:check_stall, first)
      base.send(:check_stall, second)
    end

    assert_equal first, base.instance_variable_get(:@state).stalled,
                 'First stall wins; subsequent detections are ignored'
  end

  def test_track_tool_event_triggers_stall_after_three_edit_failures
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@snapshot_builder).set_status(:triage)
    base.instance_variable_get(:@snapshot_builder).set_status(:processing)
    use_line = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u1","name":"Edit","input":{"file_path":"/a.rb","old_string":"foo"}}]}}'
    err_line = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u1","is_error":true,"content":"String not found"}]}}'

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      3.times do |i|
        indexed_use = use_line.gsub('"u1"', "\"u#{i}\"")
        indexed_err = err_line.gsub('"u1"', "\"u#{i}\"")
        base.send(:track_tool_event, indexed_use)
        base.send(:track_tool_event, indexed_err)
      end
    end

    stall = base.instance_variable_get(:@state).stalled
    refute_nil stall
    assert_equal :edit_failures, stall.reason
    assert base.instance_variable_get(:@state).stopping
  end

  def test_handle_stalled_returns_stalled_for_opus_status
    base = McptaskRunner::ClaudeCodeBase.new
    stall = McptaskRunner::StallDetector::Stall.new(reason: :edit_failures, signature: 'sig', count: 3, detail: nil)

    result = base.send(:handle_stalled, stall, Time.now - 600)

    assert_equal 'stalled_for_opus', result['status']
    refute_equal 'error', result['status'], 'Must not return error — Decider would break the loop'
    assert_equal 'edit_failures', result['reason']
    assert_equal 'sig', result['signature']
    assert_equal 3, result['count']
    assert_match(/Stalled/, result['message'])
    assert result['hours']['task_worked']
  end

  def test_handle_stalled_does_not_increment_retry_count
    base = McptaskRunner::ClaudeCodeBase.new
    stall = McptaskRunner::StallDetector::Stall.new(reason: :loop_signature, signature: 'sig', count: 4)

    base.send(:handle_stalled, stall, Time.now)

    assert_equal 0, base.instance_variable_get(:@retry_state).count,
                 'Stall is terminal; --continue retry would re-enter the same loop'
  end

  def test_raise_streaming_errors_raises_stalled_before_stream_closed
    base = McptaskRunner::ClaudeCodeBase.new
    stall = McptaskRunner::StallDetector::Stall.new(reason: :edit_failures, signature: 'sig', count: 3)
    base.instance_variable_get(:@state).stalled = stall

    error = assert_raises(McptaskRunner::StalledError) do
      base.send(:raise_streaming_errors_if_any, 'unrelated stream error')
    end
    assert_equal stall, error.stall
  end
end
