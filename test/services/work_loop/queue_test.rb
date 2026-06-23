# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

class WorkLoopQueueTest < Minitest::Test
  include TriageTestHelper

  # queue_auto_squash
  def test_execute_with_queue_auto_squash_calls_queue_auto_squash_class
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } } : { 'status' => 'no_more_tasks' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_auto_squash)

          assert_instance_of Array, results
          assert_equal 2, results.length
          assert_equal 'success', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_queue_auto_squash_stops_on_no_more_tasks
    mock = Object.new
    def mock.run
      { 'status' => 'no_more_tasks', 'hours' => { 'per_day' => 8, 'task_estimated' => 0 } }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        results = loop_instance.execute(:queue_auto_squash)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'no_more_tasks', results.first['status']
      end
    end
  end

  def test_execute_with_queue_auto_squash_stops_on_failure
    mock = Object.new
    def mock.run
      { 'status' => 'failure', 'message' => 'Error processing task' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        results = loop_instance.execute(:queue_auto_squash)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'failure', results.first['status']
      end
    end
  end

  # ci_failed is a fix-and-retry signal, NOT a stop reason — the loop continues so the
  # same task is re-picked and the CI failure gets fixed on a fresh attempt.
  def test_execute_with_queue_auto_squash_continues_on_ci_failed
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'ci_failed', 'message' => 'CI failed after retry',
          'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
      else
        { 'status' => 'no_more_tasks' }
      end
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_auto_squash)

          assert_equal 2, results.length
          assert_equal 'ci_failed', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_queue_auto_squash_continues_on_already_done
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
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_auto_squash)

          assert_equal 2, results.length
          assert_equal 'already_done', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_queue_auto_squash_continues_on_preexisting_test_errors
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
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          # Stub current_git_branch so switch_to_main_if_urgent_bug does NOT call the
          # real `git checkout main` mid-test — preexisting_test_errors is in
          # URGENT_BUG_PIN_STATUSES (triage_execution.rb:16), so without this stub the
          # test repo physically switches to main and pollutes subsequent tests in the
          # same bin/ci run.
          results = loop_instance.stub(:current_git_branch, 'main') do
            loop_instance.execute(:queue_auto_squash)
          end

          assert_equal 2, results.length
          assert_equal 'preexisting_test_errors', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_queue_auto_squash_checks_quota
    mock = Object.new
    def mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } }
    end

    decider_mock = Object.new
    def decider_mock.should_stop?
      true
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        McptaskRunner::Decider.stub(:new, decider_mock) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_auto_squash)

          assert_instance_of Array, results
          assert_equal 1, results.length
          assert_equal 'success', results.first['status']
        end
      end
    end
  end

  def test_execute_with_queue_auto_squash_ignore_quota_skips_check
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } } : { 'status' => 'no_more_tasks' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(ignore_quota: true)
          results = loop_instance.execute(:queue_auto_squash)

          assert_instance_of Array, results
          assert_equal 2, results.length
        end
      end
    end
  end

  # queue_manual
  def test_execute_with_queue_manual_calls_honest_class
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } } : { 'status' => 'no_more_tasks' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_manual)

          assert_instance_of Array, results
          assert_equal 2, results.length
          assert_equal 'success', results.first['status']
          assert_equal 'no_more_tasks', results.last['status']
        end
      end
    end
  end

  def test_execute_with_queue_manual_stops_on_no_more_tasks
    mock = Object.new
    def mock.run
      { 'status' => 'no_more_tasks', 'hours' => { 'per_day' => 8, 'task_estimated' => 0 } }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        results = loop_instance.execute(:queue_manual)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'no_more_tasks', results.first['status']
      end
    end
  end

  def test_execute_with_queue_manual_stops_on_failure
    mock = Object.new
    def mock.run
      { 'status' => 'failure', 'message' => 'Error processing task' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        results = loop_instance.execute(:queue_manual)

        assert_instance_of Array, results
        assert_equal 1, results.length
        assert_equal 'failure', results.first['status']
      end
    end
  end

  def test_execute_with_queue_manual_checks_quota
    mock = Object.new
    def mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } }
    end

    decider_mock = Object.new
    def decider_mock.should_stop?
      true
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, mock) do
        McptaskRunner::Decider.stub(:new, decider_mock) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_manual)

          assert_instance_of Array, results
          assert_equal 1, results.length
          assert_equal 'success', results.first['status']
        end
      end
    end
  end

  def test_execute_with_queue_manual_ignore_quota_skips_check
    call_count = [0]
    mock = Object.new
    mock.define_singleton_method(:run) do
      call_count[0] += 1
      call_count[0] == 1 ? { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8 } } : { 'status' => 'no_more_tasks' }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new(ignore_quota: true)
          results = loop_instance.execute(:queue_manual)

          assert_instance_of Array, results
          assert_equal 2, results.length
        end
      end
    end
  end
end
