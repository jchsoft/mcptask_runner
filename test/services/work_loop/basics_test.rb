# frozen_string_literal: true

require 'test_helper'

class WorkLoopBasicsTest < Minitest::Test
  def test_work_loop_responds_to_execute
    loop_instance = McptaskRunner::WorkLoop.new
    assert_respond_to loop_instance, :execute
  end

  def test_execute_raises_on_invalid_how
    loop_instance = McptaskRunner::WorkLoop.new
    assert_raises(ArgumentError) { loop_instance.execute(:invalid) }
  end

  def test_valid_how_values_constant
    assert_equal %i[once today daily once_dry review reviews workflow story_manual story_auto_squash today_auto_squash queue_auto_squash queue_manual once_auto_squash task_manual task_auto_squash], McptaskRunner::WorkLoop::VALID_HOW_VALUES
  end

  def test_execute_validates_how_parameter
    loop_instance = McptaskRunner::WorkLoop.new

    error = assert_raises(ArgumentError) { loop_instance.execute(:unknown) }
    assert_includes error.message, "Invalid 'how' value"
    assert_includes error.message, 'once, today, daily, once_dry, review, reviews, workflow, story_manual, story_auto_squash, today_auto_squash, queue_auto_squash, queue_manual, once_auto_squash, task_manual, task_auto_squash'
  end

  def test_verbose_mode_can_be_enabled
    loop_instance = McptaskRunner::WorkLoop.new(verbose: true)
    assert_instance_of McptaskRunner::WorkLoop, loop_instance
  end

  def test_story_id_can_be_passed_to_constructor
    loop_instance = McptaskRunner::WorkLoop.new(story_id: 999)
    assert_instance_of McptaskRunner::WorkLoop, loop_instance
  end

  def test_story_id_and_verbose_can_be_combined
    loop_instance = McptaskRunner::WorkLoop.new(verbose: true, story_id: 888)
    assert_instance_of McptaskRunner::WorkLoop, loop_instance
  end

  def test_task_id_can_be_passed_to_constructor
    loop_instance = McptaskRunner::WorkLoop.new(task_id: 999)
    assert_instance_of McptaskRunner::WorkLoop, loop_instance
  end

  def test_task_id_and_verbose_can_be_combined
    loop_instance = McptaskRunner::WorkLoop.new(verbose: true, task_id: 888)
    assert_instance_of McptaskRunner::WorkLoop, loop_instance
  end

  def test_ignore_quota_can_be_passed_to_constructor
    loop_instance = McptaskRunner::WorkLoop.new(ignore_quota: true)
    assert_instance_of McptaskRunner::WorkLoop, loop_instance
  end

  def test_ignore_quota_defaults_to_false
    loop_instance = McptaskRunner::WorkLoop.new
    refute loop_instance.send(:quota_exceeded?, [])
  end

  # Tests for no_more_tasks handling
  def test_no_tasks_available_detects_no_more_tasks_status
    loop_instance = McptaskRunner::WorkLoop.new
    result = { 'status' => 'no_more_tasks' }

    assert loop_instance.send(:no_tasks_available?, result)
  end

  def test_no_tasks_available_returns_false_for_success
    loop_instance = McptaskRunner::WorkLoop.new
    result = { 'status' => 'success' }

    refute loop_instance.send(:no_tasks_available?, result)
  end

  def test_no_tasks_available_returns_false_for_error
    loop_instance = McptaskRunner::WorkLoop.new
    result = { 'status' => 'error', 'message' => 'Some error' }

    refute loop_instance.send(:no_tasks_available?, result)
  end

  def test_end_of_workday_returns_true_after_18
    loop_instance = McptaskRunner::WorkLoop.new

    Time.stub(:now, Time.new(2025, 1, 15, 18, 30)) do
      assert loop_instance.send(:end_of_workday?)
    end
  end

  def test_end_of_workday_returns_false_before_18
    loop_instance = McptaskRunner::WorkLoop.new

    Time.stub(:now, Time.new(2025, 1, 15, 14, 30)) do
      refute loop_instance.send(:end_of_workday?)
    end
  end

  def test_handle_no_tasks_in_daily_mode_returns_false_after_workday
    loop_instance = McptaskRunner::WorkLoop.new

    Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
      refute loop_instance.send(:handle_no_tasks_in_daily_mode)
    end
  end

  def test_handle_no_tasks_in_today_auto_squash_mode_returns_false_after_workday
    loop_instance = McptaskRunner::WorkLoop.new

    Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
      refute loop_instance.send(:handle_no_tasks_in_today_auto_squash_mode)
    end
  end

  def test_handle_no_tasks_in_today_auto_squash_mode_returns_false_at_18
    loop_instance = McptaskRunner::WorkLoop.new

    Time.stub(:now, Time.new(2025, 1, 15, 18, 0)) do
      refute loop_instance.send(:handle_no_tasks_in_today_auto_squash_mode)
    end
  end

  def test_once_auto_squash_is_in_valid_how_values
    assert_includes McptaskRunner::WorkLoop::VALID_HOW_VALUES, :once_auto_squash
  end

  def test_task_manual_is_in_valid_how_values
    assert_includes McptaskRunner::WorkLoop::VALID_HOW_VALUES, :task_manual
  end

  def test_task_auto_squash_is_in_valid_how_values
    assert_includes McptaskRunner::WorkLoop::VALID_HOW_VALUES, :task_auto_squash
  end

  # On uncaught exception inside the loop, the snapshot must reflect the crash
  # before the ensure block closes the session.
  def test_flag_builder_crash_sets_error_status_with_message
    loop_instance = McptaskRunner::WorkLoop.new
    builder = McptaskRunner::SnapshotBuilder.new(session_id: "s", machine_id: "m")
    builder.set_status(:triage)
    builder.set_status(:processing)
    loop_instance.instance_variable_set(:@builder, builder)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      loop_instance.send(:flag_builder_crash, RuntimeError.new("boom"))
    end

    assert_equal "error", builder.status
    assert_equal "boom", builder.to_h[:error_message]
  end

  def test_flag_builder_crash_skips_when_already_error
    loop_instance = McptaskRunner::WorkLoop.new
    builder = McptaskRunner::SnapshotBuilder.new(session_id: "s", machine_id: "m")
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:error, error_message: "first")
    loop_instance.instance_variable_set(:@builder, builder)

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snap, **_kw) { emitted << snap }) do
      loop_instance.send(:flag_builder_crash, RuntimeError.new("second"))
    end

    assert_equal "first", builder.to_h[:error_message], "Existing error message must not be clobbered"
    assert_empty emitted, "Already-error status must not re-emit"
  end

  def test_flag_builder_crash_skips_when_finished
    loop_instance = McptaskRunner::WorkLoop.new
    builder = McptaskRunner::SnapshotBuilder.new(session_id: "s", machine_id: "m")
    builder.set_status(:triage)
    builder.set_status(:processing)
    builder.set_status(:finished)
    loop_instance.instance_variable_set(:@builder, builder)

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) do
      loop_instance.send(:flag_builder_crash, RuntimeError.new("after-finish"))
    end

    assert_equal "finished", builder.status
  end
end
