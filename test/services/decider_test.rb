# frozen_string_literal: true

require 'test_helper'

# Decider is now REST-only for the daily quota (via QuotaGuard); task-result statuses
# (error / quota_exceeded_mid_task) are the runner's own stop signals. Quota verdicts are
# driven through stub_quota; the hours block in task results no longer affects anything.
class DeciderTest < Minitest::Test
  include QuotaTestHelper

  def task(status: 'success')
    { 'status' => status }
  end

  def test_responds_to_should_continue
    assert_respond_to McptaskRunner::Decider.new, :should_continue?
  end

  def test_empty_results_never_stops
    decider = McptaskRunner::Decider.new(task_results: [])
    refute decider.should_stop?
    assert decider.should_continue?
  end

  def test_continues_when_server_under_quota
    decider = McptaskRunner::Decider.new(task_results: [task])
    stub_quota(worked: 3.0, per_day: 8.0) do
      assert decider.should_continue?
      refute decider.should_stop?
    end
  end

  def test_stops_when_server_quota_reached_exactly
    decider = McptaskRunner::Decider.new(task_results: [task])
    stub_quota(worked: 8.0, per_day: 8.0) do
      assert decider.should_stop?
    end
  end

  def test_stops_when_server_quota_exceeded
    decider = McptaskRunner::Decider.new(task_results: [task])
    stub_quota(worked: 9.5, per_day: 8.0) do
      assert decider.should_stop?
    end
  end

  def test_stops_on_holiday_per_day_zero
    decider = McptaskRunner::Decider.new(task_results: [task])
    stub_quota(worked: 0.0, per_day: 0.0) do
      assert decider.should_stop?
    end
  end

  def test_fail_closed_when_rest_unavailable
    decider = McptaskRunner::Decider.new(task_results: [task])
    stub_quota(rest_ok: false) do
      assert decider.should_stop?, 'REST failure must fail closed (stop)'
    end
  end

  def test_stops_on_task_failure_regardless_of_quota
    decider = McptaskRunner::Decider.new(task_results: [task, task(status: 'error')])
    stub_quota(worked: 0.0, per_day: 8.0) do
      assert decider.should_stop?
    end
  end

  def test_stops_on_quota_exceeded_mid_task_status
    results = [task, { 'status' => 'quota_exceeded_mid_task', 'task_id' => 999 }]
    decider = McptaskRunner::Decider.new(task_results: results)
    assert decider.should_stop?
    assert decider.quota_exceeded_mid_task?
    refute decider.should_continue?
  end

  def test_quota_exceeded_mid_task_false_when_absent
    refute McptaskRunner::Decider.new(task_results: [task]).quota_exceeded_mid_task?
  end

  def test_summary_reports_server_numbers
    decider = McptaskRunner::Decider.new(task_results: [task])
    stub_quota(worked: 2.0, per_day: 8.0) do
      summary = decider.summary
      assert_equal true, summary[:should_continue]
      assert_equal 6.0, summary[:remaining_hours]
      assert_equal 1, summary[:tasks_completed]
      assert_equal false, summary[:tasks_failed]
      assert_equal 8.0, summary[:daily_limit]
      assert_equal 2.0, summary[:total_worked]
    end
  end

  def test_accepts_single_task_result_hash
    decider = McptaskRunner::Decider.new(task_results: task)
    stub_quota(worked: 1.0, per_day: 8.0) do
      assert decider.should_continue?
    end
  end
end
