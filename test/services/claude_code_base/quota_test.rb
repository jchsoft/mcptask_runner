# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseQuotaTest < Minitest::Test
  def test_quota_exceeded_mid_task_error_exists
    assert_kind_of Class, McptaskRunner::QuotaExceededMidTaskError
    assert McptaskRunner::QuotaExceededMidTaskError < StandardError
  end

  def test_quota_watch_writer_accepts_hash
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 8.0, already_worked_hours: 7.0 }
    assert_equal 8.0, base.instance_variable_get(:@quota_watch)[:per_day_hours]
  end

  def test_quota_exceeded_now_returns_false_when_quota_watch_nil
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.send(:quota_exceeded_now?, 0.0, 100.0)
  end

  def test_quota_exceeded_now_returns_false_when_per_day_zero
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 0.0, already_worked_hours: 0.0 }
    refute base.send(:quota_exceeded_now?, 0.0, 7200.0)
  end

  def test_quota_exceeded_now_returns_false_when_under_quota
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 8.0, already_worked_hours: 6.0 }
    execution_start = 1_000.0
    now = execution_start + 3600.0 # +1h
    refute base.send(:quota_exceeded_now?, execution_start, now)
  end

  def test_quota_exceeded_now_returns_true_when_at_or_above_quota
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 8.0, already_worked_hours: 7.0 }
    execution_start = 1_000.0
    now = execution_start + 3600.0 # +1h
    assert base.send(:quota_exceeded_now?, execution_start, now)
  end

  def test_quota_exceeded_now_returns_true_when_already_exceeded_at_start
    base = McptaskRunner::ClaudeCodeBase.new
    base.quota_watch = { per_day_hours: 8.0, already_worked_hours: 9.0 }
    execution_start = 1_000.0
    assert base.send(:quota_exceeded_now?, execution_start, execution_start)
  end

  def test_reset_streaming_state_clears_quota_exceeded_flag
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).quota_exceeded = true
    base.send(:reset_streaming_state)
    refute base.instance_variable_get(:@state).quota_exceeded
  end
end
