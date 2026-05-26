# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

class WorkLoopQuotaMidTaskTest < Minitest::Test
  include TriageTestHelper

  def quota_aware_executor_mock(raise_mid_task: false, run_count: nil)
    mock = Object.new
    captured_quota = []
    mock.define_singleton_method(:quota_watch=) { |val| captured_quota << val }
    mock.define_singleton_method(:captured_quota_watch) { captured_quota.last }
    mock.define_singleton_method(:run) do
      run_count[:n] += 1 if run_count
      raise McptaskRunner::QuotaExceededMidTaskError, 'daily quota exceeded during run' if raise_mid_task

      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'task_worked' => 0.5, 'already_worked' => 0 } }
    end
    mock
  end

  def test_triage_and_execute_returns_quota_exceeded_mid_task_on_executor_raise
    executor = quota_aware_executor_mock(raise_mid_task: true)

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
        loop_instance = McptaskRunner::WorkLoop.new
        result = loop_instance.execute(:once)

        assert_equal 'quota_exceeded_mid_task', result['status']
        assert_equal 123, result['task_id']
      end
    end
  end

  def test_quota_watch_set_on_executor_with_triage_hours
    executor = quota_aware_executor_mock

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
        McptaskRunner::WorkLoop.new.execute(:once)
      end
    end

    qw = executor.captured_quota_watch
    refute_nil qw, 'quota_watch should be set on executor'
    assert_equal 8.0, qw[:per_day_hours]
    assert_equal 0.0, qw[:already_worked_hours]
  end

  def test_quota_watch_not_set_when_ignore_quota
    executor = quota_aware_executor_mock

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
        McptaskRunner::WorkLoop.new(ignore_quota: true).execute(:once)
      end
    end

    assert_nil executor.captured_quota_watch
  end

  def test_today_loop_breaks_on_mid_task_quota
    triage_call_count = { n: 0 }
    triage = Object.new
    triage.define_singleton_method(:run) do
      triage_call_count[:n] += 1
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 100 + triage_call_count[:n],
        'resuming' => false, 'hours' => { 'per_day' => 8, 'already_worked' => 0, 'task_estimated' => 2 } }
    end

    executor_run_count = { n: 0 }
    executor = quota_aware_executor_mock(raise_mid_task: true, run_count: executor_run_count)

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:today)

          assert_equal 1, results.length, 'today loop should stop after first mid-task quota'
          assert_equal 'quota_exceeded_mid_task', results.last['status']
          assert_equal 1, executor_run_count[:n], 'executor should run only once before mid-task quota terminates loop'
        end
      end
    end
  end

  def test_decider_short_circuits_on_mid_task_status
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'task_worked' => 1, 'already_worked' => 0 } },
      { 'status' => 'quota_exceeded_mid_task', 'task_id' => 999 }
    ]
    assert McptaskRunner::Decider.new(task_results: results).should_stop?
  end
end
