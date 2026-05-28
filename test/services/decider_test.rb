# frozen_string_literal: true

require 'test_helper'

class DeciderTest < Minitest::Test
  # Force TimeStatusClient.fetch to raise so the fallback (local estimates) path runs by default.
  # Without this, when `.mcp.json` and WORKVECTOR_KAMR_TOKEN are present in the dev env, fetch
  # reaches the live server and tests get real `worked_today` data instead of fixture values.
  # REST-truth tests (e.g. test_remaining_hours_uses_server_truth_when_available) wrap their
  # bodies in `TimeStatusClient.stub :fetch, ...` which layers on top of this override.
  def setup
    @original_fetch = McptaskRunner::TimeStatusClient.method(:fetch)
    McptaskRunner::TimeStatusClient.define_singleton_method(:fetch) do
      raise McptaskRunner::TimeStatusClient::Error, 'TimeStatusClient stubbed off in DeciderTest setup'
    end
  end

  def teardown
    fetch = @original_fetch
    McptaskRunner::TimeStatusClient.define_singleton_method(:fetch) { fetch.call }
  end

  def test_decider_responds_to_should_continue
    decider = McptaskRunner::Decider.new
    assert_respond_to decider, :should_continue?
  end

  def test_should_continue_with_time_remaining
    task_result = {
      'status' => 'success',
      'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'task_worked' => 0.5 }
    }
    decider = McptaskRunner::Decider.new(task_results: [task_result])

    assert decider.should_continue?
    assert !decider.should_stop?
  end

  def test_should_stop_when_daily_quota_exceeded
    # 8 hour day, estimated 5 + 4 = 9 hours (exceeds quota)
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 5.0, 'task_worked' => 5.5 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 4.0, 'task_worked' => 3.0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert decider.should_stop?
    assert !decider.should_continue?
  end

  def test_should_stop_on_task_failure
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'task_worked' => 1.0 } },
      { 'status' => 'error', 'message' => 'Failed' }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert decider.should_stop?
  end

  def test_remaining_hours_calculation
    task_result = {
      'status' => 'success',
      'hours' => { 'per_day' => 8, 'task_estimated' => 3.5, 'task_worked' => 3.5 }
    }
    decider = McptaskRunner::Decider.new(task_results: [task_result])

    assert_equal 4.5, decider.remaining_hours
  end

  def test_remaining_hours_with_multiple_accumulated_tasks
    # 8 hour day, estimated 2 + 1.5 = 3.5 hours
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2.0, 'task_worked' => 2.0 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.5, 'task_worked' => 1.5 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 4.5, decider.remaining_hours
  end

  def test_remaining_hours_exactly_zero
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 8.0, 'task_worked' => 8.0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 0, decider.remaining_hours
  end

  def test_summary_includes_all_info
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'task_worked' => 2.0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    summary = decider.summary

    assert summary.key?(:should_continue)
    assert summary.key?(:remaining_hours)
    assert summary.key?(:tasks_completed)
    assert summary.key?(:tasks_failed)
    assert summary.key?(:daily_limit)
    assert summary.key?(:total_worked)

    assert_equal true, summary[:should_continue]
    assert_equal 6.0, summary[:remaining_hours]
    assert_equal 1, summary[:tasks_completed]
    assert_equal false, summary[:tasks_failed]
    assert_equal 8.0, summary[:daily_limit]
    assert_equal 2.0, summary[:total_worked]
  end

  def test_accepts_single_task_result
    task_result = {
      'status' => 'success',
      'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'task_worked' => 1.0 }
    }
    decider = McptaskRunner::Decider.new(task_results: task_result)

    assert decider.should_continue?
    assert_equal 7.0, decider.remaining_hours
  end

  def test_remaining_hours_subtracts_already_worked
    # User already worked 5h before session, task estimated 2h → remaining = 8 - 5 - 2 = 1h
    task_result = {
      'status' => 'success',
      'hours' => { 'per_day' => 8, 'task_estimated' => 2.0, 'task_worked' => 2.0, 'already_worked' => 5.0 }
    }
    decider = McptaskRunner::Decider.new(task_results: [task_result])

    assert_equal 1.0, decider.remaining_hours
  end

  def test_already_worked_only_taken_from_first_result
    # already_worked from first result (5h), second result's already_worked is ignored
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.0, 'task_worked' => 1.0, 'already_worked' => 5.0 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.0, 'task_worked' => 1.0, 'already_worked' => 99.0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    # 8 - 5 (already) - 1 - 1 (session tasks) = 1h
    assert_equal 1.0, decider.remaining_hours
  end

  def test_should_stop_when_already_worked_exceeds_quota
    # User already worked 8h, quota is 8h → remaining = 8 - 8 - 0 = 0 → should stop
    task_result = {
      'status' => 'success',
      'hours' => { 'per_day' => 8, 'task_estimated' => 0, 'task_worked' => 0, 'already_worked' => 8.0 }
    }
    decider = McptaskRunner::Decider.new(task_results: [task_result])

    assert decider.should_stop?
  end

  def test_already_worked_missing_defaults_to_zero
    # Backward compatibility: old format without already_worked → treated as 0
    task_result = {
      'status' => 'success',
      'hours' => { 'per_day' => 8, 'task_estimated' => 3.0, 'task_worked' => 3.0 }
    }
    decider = McptaskRunner::Decider.new(task_results: [task_result])

    assert_equal 5.0, decider.remaining_hours
  end

  def test_handles_string_hour_values
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => '8', 'task_estimated' => '2.5', 'task_worked' => '2.5' } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 5.5, decider.remaining_hours
  end

  def test_empty_results_returns_zero_hours
    decider = McptaskRunner::Decider.new(task_results: [])

    assert_equal 0, decider.remaining_hours
    assert_equal 0, decider.send(:daily_hour_goal)
    assert_equal 0, decider.send(:total_hours_worked)
  end

  def test_daily_hour_goal_from_first_result
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'task_worked' => 1.0 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 10, 'task_estimated' => 1, 'task_worked' => 0.5 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    # Should use per_day from FIRST result (8, not 10)
    assert_equal 8.0, decider.send(:daily_hour_goal)
  end

  def test_daily_hour_goal_zero_means_holiday
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 0, 'task_estimated' => 0, 'task_worked' => 0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 0.0, decider.send(:daily_hour_goal), 'per_day=0 is valid (holiday); return 0 not raise'
  end

  def test_daily_hour_goal_nil_falls_back_to_24h
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => nil, 'task_estimated' => 0, 'task_worked' => 0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 24.0, decider.send(:daily_hour_goal), 'per_day=nil = API failure; fall back to 24h to keep daemon alive'
  end

  def test_total_hours_worked_sums_all_results
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'task_worked' => 1.0 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1, 'task_worked' => 1.5 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'task_worked' => 2.25 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 4.75, decider.send(:total_hours_worked)
  end

  def test_total_hours_estimated_sums_all_results
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2.0, 'task_worked' => 1.0 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.5, 'task_worked' => 1.5 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 3.25, 'task_worked' => 2.25 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert_equal 6.75, decider.send(:total_hours_estimated)
  end

  def test_should_stop_on_quota_exceeded_mid_task_status
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.0, 'task_worked' => 1.0, 'already_worked' => 0 } },
      { 'status' => 'quota_exceeded_mid_task', 'task_id' => 999 }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    assert decider.should_stop?
    assert decider.quota_exceeded_mid_task?
    refute decider.should_continue?
  end

  def test_quota_exceeded_mid_task_false_when_no_such_status
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.0, 'task_worked' => 1.0, 'already_worked' => 0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    refute decider.quota_exceeded_mid_task?
  end

  # REST truth path: when TimeStatusClient succeeds, server hours win over local estimates.
  # This is the fix for "session ran 10h with 8h quota" — estimate drift no longer leaks budget.
  def test_remaining_hours_uses_server_truth_when_available
    results = [
      # local estimates would say remaining=4.5h (8 - 0 - 1.5 - 2.0), but server says 7h already burned.
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.5, 'task_worked' => 3.0 } },
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2.0, 'task_worked' => 4.0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    McptaskRunner::TimeStatusClient.stub :fetch, { worked_today: 7.0, per_day: 8.0 } do
      assert_equal 1.0, decider.remaining_hours
      refute decider.should_stop?
    end
  end

  def test_should_stop_when_server_says_quota_exceeded
    results = [
      { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 1.0, 'task_worked' => 1.0 } }
    ]
    decider = McptaskRunner::Decider.new(task_results: results)

    McptaskRunner::TimeStatusClient.stub :fetch, { worked_today: 8.5, per_day: 8.0 } do
      assert decider.should_stop?, 'server-reported worked_today >= per_day must trigger stop'
    end
  end

  def test_falls_back_to_estimates_when_rest_fails
    # Default test env has MCPTASK_TOKEN deleted, so fetch raises → fallback path.
    # 8 - 0 - 2 (estimated) = 6 from estimates.
    task_result = { 'status' => 'success', 'hours' => { 'per_day' => 8, 'task_estimated' => 2.0, 'task_worked' => 2.0 } }
    decider = McptaskRunner::Decider.new(task_results: [task_result])

    assert_equal 6.0, decider.remaining_hours
  end
end
