# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

class WorkLoopTriageTest < Minitest::Test
  include TriageTestHelper

  def test_extract_triage_model_passes_genius_through
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:extract_triage_model, { 'recommended_model' => 'genius' })
    assert_equal 'genius', result
  end

  def test_extract_triage_model_maps_smart_to_smart
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:extract_triage_model, { 'recommended_model' => 'smart' })
    assert_equal 'smart', result
  end

  def test_extract_triage_model_accepts_primitive
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:extract_triage_model, { 'recommended_model' => 'primitive' })
    assert_equal 'primitive', result
  end

  def test_extract_triage_model_defaults_to_genius_for_unknown
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:extract_triage_model, { 'recommended_model' => 'gpt4' })
    assert_equal 'genius', result
  end

  def test_extract_triage_model_defaults_to_genius_for_nil
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:extract_triage_model, { 'recommended_model' => nil })
    assert_equal 'genius', result
  end

  def test_triage_no_more_tasks_short_circuits
    no_tasks_mock = Object.new
    def no_tasks_mock.run
      { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
    end

    executor_called = false
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      executor_called = true
      { 'status' => 'success' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, no_tasks_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        result = loop_instance.execute(:once)

        assert_equal 'no_more_tasks', result['status']
        refute executor_called, 'Executor should not be called when triage returns no_more_tasks'
      end
    end
  end

  def test_detect_task_id_from_branch_returns_nil_on_main
    loop_instance = McptaskRunner::WorkLoop.new
    # We're on main in this repo
    assert_nil loop_instance.send(:detect_task_id_from_branch)
  end

  def test_detect_task_id_from_branch_extracts_id_from_feature_branch
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.stub(:`, "feature/9508-contact-page\n") do
      assert_equal 9508, loop_instance.send(:detect_task_id_from_branch)
    end
  end

  def test_detect_task_id_from_branch_returns_nil_for_branch_without_id
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.stub(:`, "fix/typo\n") do
      assert_nil loop_instance.send(:detect_task_id_from_branch)
    end
  end

  def test_triage_uses_branch_task_id_when_no_explicit_id
    triage_kwargs = nil
    mock = Object.new
    def mock.run
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 9508,
        'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
    end

    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, ->(**kwargs) { triage_kwargs = kwargs; mock }) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.stub(:detect_task_id_from_branch, 9508) do
          loop_instance.execute(:once)
        end

        assert_equal 9508, triage_kwargs[:task_id]
      end
    end
  end

  def test_triage_passes_model_override_to_executor
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 999,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'already_worked' => 0 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::OnceAutoSquash.stub(:new, ->(** kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once_auto_squash)

        assert_equal 'smart', received_kwargs[:model_override]
        assert_equal 999, received_kwargs[:task_id]
        assert_equal false, received_kwargs[:resuming]
      end
    end
  end

  def test_triage_explicit_task_id_not_overridden_by_triage
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 9809,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::TaskAutoSquash.stub(:new, ->(**kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new(task_id: 9901)
        loop_instance.execute(:task_auto_squash)

        assert_equal 9901, received_kwargs[:task_id],
                     'Explicit task_id should not be overridden by triage result'
      end
    end
  end

  def test_triage_passes_resuming_true_to_executor
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 9508,
        'resuming' => true, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 1 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, ->(**kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once)

        assert_equal true, received_kwargs[:resuming]
        assert_equal 9508, received_kwargs[:task_id]
      end
    end
  end

  def test_resuming_upgrades_smart_to_genius
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 9508,
        'resuming' => true, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 1 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, ->(**kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once)

        assert_equal 'genius', received_kwargs[:model_override],
                     'Resuming task must run on genius even when triage recommended sonnet'
        assert_equal true, received_kwargs[:resuming]
      end
    end
  end

  def test_resuming_upgrades_haiku_to_genius
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'primitive', 'task_id' => 9508,
        'resuming' => true, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 1 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, ->(**kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once)

        assert_equal 'genius', received_kwargs[:model_override]
      end
    end
  end

  def test_resuming_false_keeps_smart
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 9508,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 1 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, ->(**kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once)

        assert_equal 'smart', received_kwargs[:model_override],
                     'Fresh tasks must keep triage recommendation'
      end
    end
  end

  def test_upgrade_model_for_resume_unit
    loop_instance = McptaskRunner::WorkLoop.new

    assert_equal 'genius',   loop_instance.send(:upgrade_model_for_resume, 'smart', true)
    assert_equal 'genius',   loop_instance.send(:upgrade_model_for_resume, 'primitive',  true)
    assert_equal 'genius',   loop_instance.send(:upgrade_model_for_resume, 'genius',   true)
    assert_equal 'smart', loop_instance.send(:upgrade_model_for_resume, 'smart', false)
    assert_equal 'primitive',  loop_instance.send(:upgrade_model_for_resume, 'primitive',  false)
  end

  # Story detection from @next tests

  def test_story_executor_mapping
    loop_instance = McptaskRunner::WorkLoop.new

    assert_equal McptaskRunner::ClaudeCode::StoryManual,
                 loop_instance.send(:story_executor_for, McptaskRunner::ClaudeCode::Honest)
    assert_equal McptaskRunner::ClaudeCode::StoryAutoSquash,
                 loop_instance.send(:story_executor_for, McptaskRunner::ClaudeCode::TodayAutoSquash)
    assert_equal McptaskRunner::ClaudeCode::StoryAutoSquash,
                 loop_instance.send(:story_executor_for, McptaskRunner::ClaudeCode::OnceAutoSquash)
    assert_equal McptaskRunner::ClaudeCode::StoryAutoSquash,
                 loop_instance.send(:story_executor_for, McptaskRunner::ClaudeCode::QueueAutoSquash)
  end

  def test_story_executor_mapping_defaults_to_story_manual
    loop_instance = McptaskRunner::WorkLoop.new

    assert_equal McptaskRunner::ClaudeCode::StoryManual,
                 loop_instance.send(:story_executor_for, McptaskRunner::ClaudeCode::Review)
  end

  def test_story_detected_switches_to_story_loop
    call_count = 0
    story_triage_mock = Object.new
    story_triage_mock.define_singleton_method(:run) do
      call_count += 1
      if call_count <= 1
        { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 555,
          'piece_type' => 'Story', 'story_id' => 8965,
          'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
      else
        { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
      end
    end

    story_executor_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, story_triage_mock) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, ->(**kwargs) { story_executor_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        result = loop_instance.execute(:once)

        # Should have used StoryManual (not Honest)
        assert story_executor_kwargs, 'StoryManual should have been called'
        assert_equal 8965, story_executor_kwargs[:story_id]
        assert_equal 555, story_executor_kwargs[:task_id]
      end
    end
  end

  def test_story_detected_in_auto_squash_uses_story_auto_squash
    story_triage_mock = Object.new
    def story_triage_mock.run
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 555,
        'piece_type' => 'Story', 'story_id' => 8965,
        'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
    end

    story_executor_called = false
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      story_executor_called = true
      { 'status' => 'no_more_tasks' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, story_triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, ->(**_kwargs) { executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once_auto_squash)

        assert story_executor_called, 'StoryAutoSquash should have been called'
      end
    end
  end

  # Regression: run_story_loop iter 1 used to call story_executor.new without
  # snapshot_builder:, so it built a fresh SnapshotBuilder. The WorkLoop builder
  # stayed at "processing" (set by outer triage_and_execute) and iter 2's
  # set_status(:triage) raised InvalidTransitionError.
  def test_story_loop_first_iteration_passes_workloop_builder_to_executor
    triage_mock_obj = Object.new
    def triage_mock_obj.run
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 100,
        'piece_type' => 'Story', 'story_id' => 8965,
        'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'already_worked' => 0 } }
    end

    captured_kwargs = nil
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      { 'status' => 'no_more_tasks', 'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
    end
    executor_mock.define_singleton_method(:quota_watch=) { |_| nil }

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock_obj) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, ->(**kwargs) { captured_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once)

        refute_nil captured_kwargs, 'StoryManual.new should have been called for iter 1'
        builder = loop_instance.instance_variable_get(:@builder)
        assert_equal builder.object_id, captured_kwargs[:snapshot_builder].object_id,
                     'story_executor.new must receive the WorkLoop builder so state transitions stay coherent'
      end
    end
  end

  def test_story_loop_processes_multiple_subtasks
    triage_call_count = 0
    triage_mock_obj = Object.new
    triage_mock_obj.define_singleton_method(:run) do
      triage_call_count += 1
      case triage_call_count
      when 1
        { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 100,
          'piece_type' => 'Story', 'story_id' => 8965,
          'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'already_worked' => 0 } }
      when 2
        { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 101,
          'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'already_worked' => 1 } }
      else
        { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
      end
    end

    executor_call_count = 0
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      executor_call_count += 1
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock_obj) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, ->(**_kwargs) { executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new
        loop_instance.execute(:once)

        assert_equal 2, executor_call_count, 'Should have processed 2 subtasks before no_more_tasks'
      end
    end
  end

  def test_explicit_story_id_does_not_trigger_story_loop_again
    # When already in story mode (kwargs[:story_id] present), don't re-trigger story loop
    triage_result_mock = Object.new
    def triage_result_mock.run
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 555,
        'piece_type' => 'Story', 'story_id' => 8965,
        'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
    end

    story_manual_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'no_more_tasks' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_result_mock) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, ->(**kwargs) { story_manual_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 8965)
        loop_instance.execute(:story_manual)

        # Should call StoryManual directly (not enter story_loop again)
        assert story_manual_kwargs, 'StoryManual should have been called directly'
        assert_equal 555, story_manual_kwargs[:task_id]
      end
    end
  end
end