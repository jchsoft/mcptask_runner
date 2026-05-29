# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

class WorkLoopTodayAutoSquashTest < Minitest::Test
  include TriageTestHelper

  def test_execute_with_today_auto_squash_calls_today_auto_squash_class
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } } : { 'status' => 'no_more_tasks' }
    end

    decider_mock = Object.new
    def decider_mock.should_stop?
      false
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        McptaskRunner::Decider.stub(:new, decider_mock) do
          Kernel.stub(:sleep, nil) do
            Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
              loop_instance = McptaskRunner::WorkLoop.new
              results = loop_instance.execute(:today_auto_squash)

              assert_instance_of Array, results
              assert_equal 2, results.length
              assert_equal 'success', results.first['status']
              assert_equal 'no_more_tasks', results.last['status']
            end
          end
        end
      end
    end
  end

  def test_execute_with_today_auto_squash_stops_on_no_more_tasks
    mock = Object.new
    def mock.run
      { 'status' => 'no_more_tasks', 'hours' => { 'per_day' => 8, 'task_estimated' => 0 } }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:today_auto_squash)

          assert_instance_of Array, results
          assert_equal 1, results.length
          assert_equal 'no_more_tasks', results.first['status']
        end
      end
    end
  end

  def test_execute_with_today_auto_squash_stops_immediately_after_workday
    mock = Object.new
    def mock.run
      { 'status' => 'no_more_tasks' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        Time.stub(:now, Time.new(2025, 1, 15, 18, 0)) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:today_auto_squash)

          assert_equal 1, results.length
          assert_equal 'no_more_tasks', results.first['status']
        end
      end
    end
  end

  def test_execute_with_today_auto_squash_stops_on_failure
    mock = Object.new
    def mock.run
      { 'status' => 'failure', 'message' => 'Error processing task' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        results = loop_instance.execute(:today_auto_squash)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'failure', results.first['status']
      end
    end
  end

  def test_execute_with_today_auto_squash_stops_on_ci_failed
    mock = Object.new
    def mock.run
      { 'status' => 'ci_failed', 'message' => 'CI failed after retry' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        results = loop_instance.execute(:today_auto_squash)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'ci_failed', results.first['status']
      end
    end
  end

  def test_execute_with_today_auto_squash_continues_on_already_done
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'already_done', 'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
      else
        { 'status' => 'no_more_tasks' }
      end
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
            loop_instance = McptaskRunner::WorkLoop.new
            results = loop_instance.execute(:today_auto_squash)

            assert_equal 2, results.length
            assert_equal 'already_done', results.first['status']
            assert_equal 'no_more_tasks', results.last['status']
          end
        end
      end
    end
  end

  def test_execute_with_today_auto_squash_continues_on_preexisting_test_errors
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'preexisting_test_errors', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
      else
        { 'status' => 'no_more_tasks' }
      end
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
            loop_instance = McptaskRunner::WorkLoop.new
            results = loop_instance.execute(:today_auto_squash)

            assert_equal 2, results.length
            assert_equal 'preexisting_test_errors', results.first['status']
            assert_equal 'no_more_tasks', results.last['status']
          end
        end
      end
    end
  end

  # First iteration returns urgent_bug_pending → runner pins the bug and the SECOND iteration
  # bypasses triage, running the urgent-bug executor (TodayAutoSquash → TaskAutoSquash per
  # URGENT_BUG_EXECUTOR_MAP), which must be stubbed too. current_git_branch is stubbed to 'main'
  # so the pin is written without a real git checkout, making the test independent of the CI branch.
  def test_execute_with_today_auto_squash_continues_on_urgent_bug_pending
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999,
          'hours' => { 'per_day' => 8, 'task_estimated' => 1 } }
      else
        { 'status' => 'no_more_tasks' }
      end
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        McptaskRunner::ClaudeCode::TaskAutoSquash.stub(:new, mock) do
          Kernel.stub(:sleep, nil) do
            Time.stub(:now, Time.new(2025, 1, 15, 19, 0)) do
              loop_instance = McptaskRunner::WorkLoop.new
              results = loop_instance.stub(:current_git_branch, 'main') do
                loop_instance.execute(:today_auto_squash)
              end

              assert_equal 2, results.length
              assert_equal 'urgent_bug_pending', results.first['status']
              assert_equal 'no_more_tasks', results.last['status']
            end
          end
        end
      end
    end
  end

  def test_execute_with_today_auto_squash_checks_quota
    mock = Object.new
    def mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } }
    end

    decider_mock = Object.new
    def decider_mock.should_stop?
      true
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::TodayAutoSquash.stub(:new, mock) do
        McptaskRunner::Decider.stub(:new, decider_mock) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:today_auto_squash)

          assert_instance_of Array, results
          assert_equal 1, results.length
          assert_equal 'success', results.first['status']
        end
      end
    end
  end
end
