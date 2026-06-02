# frozen_string_literal: true

require 'test_helper'

# Mid-task quota guard is now a throttled LIVE REST poll (QuotaGuard.status), not a frozen
# snapshot + wall-clock. @quota_watch only gates whether the guard is armed; the verdict is
# always live. A monotonic `now` >> QUOTA_POLL_INTERVAL apart between calls forces re-polls.
class ClaudeCodeBaseQuotaTest < Minitest::Test
  include QuotaTestHelper

  POLL = McptaskRunner::Concerns::HeartbeatMonitoring::QUOTA_POLL[:interval]

  def armed_base
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 8.0, already_worked_hours: 0.0 }
    base
  end

  def test_quota_exceeded_mid_task_error_exists
    assert_kind_of Class, McptaskRunner::QuotaExceededMidTaskError
    assert McptaskRunner::QuotaExceededMidTaskError < StandardError
  end

  def test_quota_watch_writer_accepts_hash
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 8.0, already_worked_hours: 7.0 }
    assert_equal 8.0, base.instance_variable_get(:@quota_watch)[:per_day_hours]
  end

  def test_quota_exceeded_now_false_when_guard_disarmed
    base = McptaskRunner::ClaudeCodeBase.new # no quota_watch
    stub_quota(worked: 99.0, per_day: 8.0) do
      refute base.send(:quota_exceeded_now?, 1_000_000.0)
    end
  end

  def test_quota_exceeded_now_false_when_server_under_quota
    stub_quota(worked: 6.0, per_day: 8.0) do
      refute armed_base.send(:quota_exceeded_now?, 1_000_000.0)
    end
  end

  def test_quota_exceeded_now_true_when_server_at_quota
    stub_quota(worked: 8.0, per_day: 8.0) do
      assert armed_base.send(:quota_exceeded_now?, 1_000_000.0)
    end
  end

  def test_quota_exceeded_now_throttles_between_polls
    base = armed_base
    stub_quota(worked: 9.0, per_day: 8.0) do
      assert base.send(:quota_exceeded_now?, 1_000_000.0) # first poll fires
      refute base.send(:quota_exceeded_now?, 1_000_000.0 + (POLL / 2.0)) # within interval → throttled
    end
  end

  def test_quota_exceeded_now_fail_closed_after_consecutive_rest_failures
    base = armed_base
    stub_quota(rest_ok: false) do
      refute base.send(:quota_exceeded_now?, 1_000_000.0)             # failure 1
      refute base.send(:quota_exceeded_now?, 1_000_000.0 + (POLL * 1.5)) # failure 2
      assert base.send(:quota_exceeded_now?, 1_000_000.0 + (POLL * 3))   # failure 3 → fail-closed kill
    end
  end

  def test_reset_streaming_state_clears_quota_exceeded_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).quota_exceeded = true
    base.send(:reset_streaming_state)
    refute base.instance_variable_get(:@state).quota_exceeded
  end
end
