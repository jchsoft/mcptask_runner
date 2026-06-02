# frozen_string_literal: true

require 'test_helper'

# DailyScheduler is REST-only (QuotaGuard). Two deliberately different fail directions:
# - quota checks fail CLOSED (a REST blip stops new work, never overruns)
# - can_work_today? fails OPEN (a blip must not condemn the whole day to wait_until_next_day)
class DailySchedulerTest < Minitest::Test
  include QuotaTestHelper

  def scheduler
    McptaskRunner::DailyScheduler.new(task_results: [])
  end

  def test_can_work_today_true_when_per_day_positive
    stub_quota(worked: 0.0, per_day: 8.0) { assert scheduler.can_work_today? }
  end

  def test_can_work_today_false_when_per_day_zero
    stub_quota(worked: 0.0, per_day: 0.0) { refute scheduler.can_work_today? }
  end

  def test_can_work_today_true_when_rest_unavailable
    stub_quota(rest_ok: false) do
      assert scheduler.can_work_today?, 'a REST blip must not condemn the whole day'
    end
  end

  def test_should_continue_working_when_under_quota
    stub_quota(worked: 2.0, per_day: 8.0) { assert scheduler.should_continue_working? }
  end

  def test_should_continue_working_false_when_quota_exceeded
    stub_quota(worked: 8.5, per_day: 8.0) { refute scheduler.should_continue_working? }
  end

  def test_should_continue_working_false_when_rest_unavailable
    stub_quota(rest_ok: false) do
      refute scheduler.should_continue_working?, 'quota check fails closed'
    end
  end

  def test_wait_reason_zero_quota
    stub_quota(worked: 0.0, per_day: 0.0) { assert_equal :zero_quota, scheduler.wait_reason }
  end

  def test_wait_reason_quota_exceeded
    stub_quota(worked: 8.5, per_day: 8.0) { assert_equal :quota_exceeded, scheduler.wait_reason }
  end

  def test_wait_reason_nil_when_can_continue
    stub_quota(worked: 2.0, per_day: 8.0) { assert_nil scheduler.wait_reason }
  end
end
