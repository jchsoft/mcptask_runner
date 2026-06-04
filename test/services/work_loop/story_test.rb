# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

class WorkLoopStoryTest < Minitest::Test
  include TriageTestHelper

  # Story modes now go through triage_and_execute for model selection

  def test_execute_with_story_manual_requires_story_id
    loop_instance = McptaskRunner::WorkLoop.new
    error = assert_raises(ArgumentError) { loop_instance.execute(:story_manual) }
    assert_includes error.message, 'story_id is required'
  end

  def test_execute_with_story_manual_calls_story_manual_class
    call_count = [0]
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'story_id' => 123, 'task_id' => 456, 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } } : { 'status' => 'no_more_tasks' }
    end

    triage_call_count = [0]
    triage_mock_obj = Object.new
    triage_mock_obj.define_singleton_method(:run) do
      triage_call_count[0] += 1
      if triage_call_count[0] <= 2
        { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 456,
          'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
      else
        { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
      end
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock_obj) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, executor_mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
          results = loop_instance.execute(:story_manual)

          assert_instance_of Array, results
          assert_equal 2, results.length
          assert_equal 'success', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_story_manual_stops_on_no_more_tasks
    triage_no_tasks = Object.new
    def triage_no_tasks.run
      { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_no_tasks) do
      loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
      results = loop_instance.execute(:story_manual)

      assert_instance_of Array, results
      assert_equal 1, results.length
      assert_equal 'no_more_tasks', results.first['status']
    end
  end

  def test_execute_with_story_manual_stops_on_failure
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'failure', 'message' => 'Error processing task' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
        results = loop_instance.execute(:story_manual)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'failure', results.first['status']
      end
    end
  end

  def test_execute_with_story_auto_squash_requires_story_id
    loop_instance = McptaskRunner::WorkLoop.new
    error = assert_raises(ArgumentError) { loop_instance.execute(:story_auto_squash) }
    assert_includes error.message, 'story_id is required'
  end

  def test_execute_with_story_auto_squash_calls_story_auto_squash_class
    call_count = [0]
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'story_id' => 123, 'task_id' => 456, 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } } : { 'status' => 'no_more_tasks' }
    end

    triage_call_count = [0]
    triage_mock_obj = Object.new
    triage_mock_obj.define_singleton_method(:run) do
      triage_call_count[0] += 1
      if triage_call_count[0] <= 2
        { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 456,
          'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
      else
        { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
      end
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock_obj) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
          results = loop_instance.execute(:story_auto_squash)

          assert_instance_of Array, results
          assert_equal 2, results.length
          assert_equal 'success', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_story_auto_squash_stops_on_no_more_tasks
    triage_no_tasks = Object.new
    def triage_no_tasks.run
      { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_no_tasks) do
      loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
      results = loop_instance.execute(:story_auto_squash)

      assert_instance_of Array, results
      assert_equal 1, results.length
      assert_equal 'no_more_tasks', results.first['status']
    end
  end

  def test_execute_with_story_auto_squash_stops_on_failure
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'failure', 'message' => 'Error processing task' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
        results = loop_instance.execute(:story_auto_squash)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'failure', results.first['status']
      end
    end
  end

  def test_execute_with_story_auto_squash_continues_on_already_done
    call_count = [0]
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'already_done', 'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
      else
        { 'status' => 'no_more_tasks' }
      end
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
          results = loop_instance.execute(:story_auto_squash)

          assert_equal 2, results.length
          assert_equal 'already_done', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_story_auto_squash_continues_on_preexisting_test_errors
    call_count = [0]
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'preexisting_test_errors', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
      else
        { 'status' => 'no_more_tasks' }
      end
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
          # Stub current_git_branch so switch_to_main_if_urgent_bug does NOT call the
          # real `git checkout main` mid-test — preexisting_test_errors is in
          # URGENT_BUG_PIN_STATUSES (triage_execution.rb:16), so without this stub the
          # test repo physically switches to main and pollutes subsequent tests in the
          # same bin/ci run.
          results = loop_instance.stub(:current_git_branch, 'main') do
            loop_instance.execute(:story_auto_squash)
          end

          assert_equal 2, results.length
          assert_equal 'preexisting_test_errors', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_story_auto_squash_stops_on_ci_failed
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'ci_failed', 'message' => 'CI failed after retry' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
        # Stub current_git_branch defensively — ci_failed is not in URGENT_BUG_PIN_STATUSES
        # today, but matching the sibling tests keeps the suite immune to future list changes.
        results = loop_instance.stub(:current_git_branch, 'main') do
          loop_instance.execute(:story_auto_squash)
        end

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'ci_failed', results.first['status']
      end
    end
  end

  def test_story_manual_triage_passes_story_id
    triage_kwargs = nil
    triage_mock_obj = Object.new
    def triage_mock_obj.run
      { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 789,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'already_worked' => 0 } }
    end

    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'no_more_tasks' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, ->(**kwargs) { triage_kwargs = kwargs; triage_mock_obj }) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 555)
        loop_instance.execute(:story_manual)

        assert_equal 555, triage_kwargs[:story_id]
      end
    end
  end

  def test_execute_with_story_manual_stops_on_quota_exceeded
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } }
    end

    decider_mock = Object.new
    def decider_mock.should_stop?
      true
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, executor_mock) do
        McptaskRunner::Decider.stub(:new, decider_mock) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
          results = loop_instance.execute(:story_manual)

          assert_instance_of Array, results
          assert_equal 1, results.length
          assert_equal 'success', results.first['status']
        end
      end
    end
  end

  def test_execute_with_story_manual_ignore_quota_skips_check
    call_count = [0]
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } } : { 'status' => 'no_more_tasks' }
    end

    triage_call_count = [0]
    triage_mock_obj = Object.new
    triage_mock_obj.define_singleton_method(:run) do
      triage_call_count[0] += 1
      if triage_call_count[0] <= 2
        { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 456,
          'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 8, 'already_worked' => 0 } }
      else
        { 'status' => 'no_more_tasks', 'recommended_model' => 'genius' }
      end
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock_obj) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, executor_mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123, ignore_quota: true)
          results = loop_instance.execute(:story_manual)

          assert_instance_of Array, results
          assert_equal 2, results.length
        end
      end
    end
  end

  def test_execute_with_story_auto_squash_stops_on_quota_exceeded
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } }
    end

    decider_mock = Object.new
    def decider_mock.should_stop?
      true
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        McptaskRunner::Decider.stub(:new, decider_mock) do
          loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
          results = loop_instance.execute(:story_auto_squash)

          assert_instance_of Array, results
          assert_equal 1, results.length
          assert_equal 'success', results.first['status']
        end
      end
    end
  end

  def test_execute_with_story_manual_stops_on_urgent_bug_pending
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999, 'task_id' => 456,
        'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
        # Stub current_git_branch so switch_to_main_if_urgent_bug (triage_execution.rb:149)
        # does NOT call the real `git checkout main` mid-test — same pattern as
        # today_auto_squash_test.rb:195. Without this, the test repo physically switches
        # to main and pollutes subsequent tests in the same bin/ci run.
        results = loop_instance.stub(:current_git_branch, 'main') do
          loop_instance.execute(:story_manual)
        end

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'urgent_bug_pending', results.first['status']
        assert_equal 9999, results.first['bug_task_id']
      end
    end
  end

  def test_execute_with_story_auto_squash_stops_on_urgent_bug_pending
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999, 'task_id' => 456,
        'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 123)
        # Stub current_git_branch so switch_to_main_if_urgent_bug does NOT call the real
        # `git checkout main` mid-test — same pattern as today_auto_squash_test.rb:195.
        results = loop_instance.stub(:current_git_branch, 'main') do
          loop_instance.execute(:story_auto_squash)
        end

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'urgent_bug_pending', results.first['status']
        assert_equal 9999, results.first['bug_task_id']
      end
    end
  end

  def test_story_manual_triage_passes_model_and_task_id_to_executor
    triage_mock_obj = Object.new
    def triage_mock_obj.run
      { 'status' => 'success', 'recommended_model' => 'smart', 'task_id' => 789,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'already_worked' => 0 } }
    end

    received_kwargs = nil
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'no_more_tasks' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock_obj) do
      McptaskRunner::ClaudeCode::StoryManual.stub(:new, ->(**kwargs) { received_kwargs = kwargs; executor_mock }) do
        loop_instance = McptaskRunner::WorkLoop.new(story_id: 555)
        loop_instance.execute(:story_manual)

        assert_equal 'smart', received_kwargs[:model_override]
        assert_equal 789, received_kwargs[:task_id]
        assert_equal 555, received_kwargs[:story_id]
        assert_equal false, received_kwargs[:resuming]
      end
    end
  end
end
