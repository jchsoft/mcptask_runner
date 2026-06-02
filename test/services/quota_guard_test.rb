# frozen_string_literal: true

require 'test_helper'

# QuotaGuard maps the live REST numbers to a stop/continue verdict. These tests exercise the
# INSTANCE method (#status) with TimeStatusClient.fetch stubbed, bypassing the class-level
# under-quota default that test_helper installs for everyone else.
class QuotaGuardTest < Minitest::Test
  def status_with(fetch_result)
    McptaskRunner::TimeStatusClient.stub(:fetch, fetch_result) { McptaskRunner::QuotaGuard.new.status }
  end

  def test_not_exceeded_when_under
    status = status_with({ worked_today: 3.0, per_day: 8.0 })
    refute status.exceeded
    assert status.rest_ok
    assert_equal 3.0, status.worked_today
    assert_equal 8.0, status.per_day
  end

  def test_exceeded_when_at_goal
    refute status_with({ worked_today: 7.9, per_day: 8.0 }).exceeded
    assert status_with({ worked_today: 8.0, per_day: 8.0 }).exceeded
    assert status_with({ worked_today: 11.0, per_day: 8.0 }).exceeded
  end

  def test_exceeded_on_holiday_zero_goal
    assert status_with({ worked_today: 0.0, per_day: 0.0 }).exceeded
  end

  def test_fail_closed_on_rest_error
    raiser = ->(*) { raise McptaskRunner::TimeStatusClient::Error, 'down' }
    status = status_with(raiser)
    assert status.exceeded, 'REST failure must report exceeded (fail-closed)'
    refute status.rest_ok
  end
end
