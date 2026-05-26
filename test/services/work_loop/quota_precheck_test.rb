# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

class WorkLoopQuotaPrecheckTest < Minitest::Test
  include TriageTestHelper

  def quota_exceeded_triage_mock(task_id: 123)
    mock = Object.new
    mock.define_singleton_method(:run) do
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => task_id,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'already_worked' => 22.3, 'task_estimated' => 2 } }
    end
    mock
  end

  def test_triage_and_execute_skips_execution_when_quota_exceeded
    executor_called = false
    executor_mock = Object.new
    executor_mock.define_singleton_method(:run) do
      executor_called = true
      { 'status' => 'success' }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, quota_exceeded_triage_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        result = loop_instance.execute(:once)

        assert_equal 'quota_exceeded', result['status']
        refute executor_called, 'Executor should not be called when quota is already exceeded'
      end
    end
  end

  def test_triage_and_execute_proceeds_when_ignore_quota
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, quota_exceeded_triage_mock) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new(ignore_quota: true)
        result = loop_instance.execute(:once)

        assert_equal 'success', result['status']
      end
    end
  end

  def triage_status_quota_exceeded_mock
    mock = Object.new
    mock.define_singleton_method(:run) do
      { 'status' => 'quota_exceeded', 'recommended_model' => 'genius', 'task_id' => 0,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'already_worked' => 9, 'task_estimated' => 0 } }
    end
    mock
  end

  def test_triage_status_quota_exceeded_short_circuits_without_ignore_quota
    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_status_quota_exceeded_mock) do
      result = McptaskRunner::WorkLoop.new.execute(:once)
      assert_equal 'quota_exceeded', result['status']
    end
  end

  def test_triage_status_quota_exceeded_bypassed_when_ignore_quota
    executor_mock = Object.new
    executor_called = false
    executor_mock.define_singleton_method(:run) do
      executor_called = true
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    triage = Object.new
    triage.define_singleton_method(:run) do
      { 'status' => 'quota_exceeded', 'recommended_model' => 'genius', 'task_id' => 555,
        'resuming' => false, 'hours' => { 'per_day' => 8, 'already_worked' => 9, 'task_estimated' => 0 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage) do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor_mock) do
        result = McptaskRunner::WorkLoop.new(ignore_quota: true).execute(:once)
        assert_equal 'success', result['status']
        assert executor_called, 'Executor must run when ignore_quota=true even if triage flagged quota_exceeded'
      end
    end
  end

  def test_triage_and_execute_proceeds_when_quota_not_exceeded
    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor_mock) do
        loop_instance = McptaskRunner::WorkLoop.new
        result = loop_instance.execute(:once)

        assert_equal 'success', result['status']
      end
    end
  end

  def test_triage_quota_exceeded_returns_false_when_no_hours
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:triage_quota_exceeded?, { 'status' => 'success' })
    refute result
  end

  def test_triage_quota_exceeded_returns_true_when_already_worked_exceeds_per_day
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:triage_quota_exceeded?,
                                { 'hours' => { 'per_day' => 8, 'already_worked' => 10 } })
    assert result
  end

  def test_triage_quota_exceeded_returns_true_when_exactly_equal
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:triage_quota_exceeded?,
                                { 'hours' => { 'per_day' => 8, 'already_worked' => 8 } })
    assert result
  end

  def test_triage_quota_exceeded_returns_false_when_under_quota
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:triage_quota_exceeded?,
                                { 'hours' => { 'per_day' => 8, 'already_worked' => 5 } })
    refute result
  end

  def test_triage_quota_exceeded_returns_true_when_per_day_is_zero_holiday
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:triage_quota_exceeded?,
                                { 'hours' => { 'per_day' => 0, 'already_worked' => 0 } })
    assert result, 'per_day=0 means no work today (holiday); must report quota exceeded'
  end

  def test_triage_quota_exceeded_returns_false_when_per_day_is_nil_api_failure
    loop_instance = McptaskRunner::WorkLoop.new
    result = loop_instance.send(:triage_quota_exceeded?,
                                { 'hours' => { 'per_day' => nil, 'already_worked' => 0 } })
    refute result, 'per_day=nil means API read failed; skip check, do not crash daemon'
  end

  def test_queue_auto_squash_breaks_on_quota_exceeded
    call_count = [0]
    triage = Object.new
    triage.define_singleton_method(:run) do
      call_count[0] += 1
      if call_count[0] == 1
        { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 123,
          'resuming' => false, 'hours' => { 'per_day' => 8, 'already_worked' => 0, 'task_estimated' => 2 } }
      else
        { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => 456,
          'resuming' => false, 'hours' => { 'per_day' => 8, 'already_worked' => 22.3, 'task_estimated' => 2 } }
      end
    end

    executor_mock = Object.new
    def executor_mock.run
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2 } }
    end

    McptaskRunner::ClaudeCode::Triage.stub(:new, triage) do
      McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, executor_mock) do
        Kernel.stub(:sleep, nil) do
          loop_instance = McptaskRunner::WorkLoop.new
          results = loop_instance.execute(:queue_auto_squash)

          assert_equal 2, results.length
          assert_equal 'success', results.first['status']
          assert_equal 'quota_exceeded', results.last['status']
        end
      end
    end
  end
end
