require 'test_helper'

class WaitingStrategyTest < Minitest::Test
  def test_wait_one_hour_sleeps
    strategy = McptaskRunner::WaitingStrategy.new
    sleep_until_called = false
    strategy.stub :sleep_until, ->(_target_time, builder: nil) { sleep_until_called = true } do
      assert_output(/Waiting 1 hour before retry/) { strategy.wait_one_hour }
    end
    assert sleep_until_called
  end

  def test_wait_until_next_day_calls_sleep
    strategy = McptaskRunner::WaitingStrategy.new
    sleep_until_called = false

    # Mock Time.now to a known time (Monday 9 PM)
    mock_time = Time.new(2025, 11, 3, 21, 0, 0)
    Time.stub :now, mock_time do
      strategy.stub :sleep_until, ->(_target_time, builder: nil) { sleep_until_called = true } do
        assert_output(/Waiting/) { strategy.wait_until_next_day }
        assert sleep_until_called
      end
    end
  end

  def test_wait_until_next_day_skips_weekends
    strategy = McptaskRunner::WaitingStrategy.new

    # Mock Time.now to Friday
    mock_time = Time.new(2025, 11, 7, 21, 0, 0) # Friday 9 PM
    sleep_until_calls = []
    Time.stub :now, mock_time do
      strategy.stub :sleep_until, ->(target_time, builder: nil) { sleep_until_calls << target_time } do
        assert_output(/Waiting/) { strategy.wait_until_next_day }
      end
    end

    # Should wait until Monday 8 AM (not Saturday or Sunday)
    assert_equal 1, sleep_until_calls.length
    assert_equal 1, sleep_until_calls[0].wday # Monday
    assert_equal 8, sleep_until_calls[0].hour
  end

  def test_sleep_until_emits_heartbeat_snapshot_per_chunk
    strategy = McptaskRunner::WaitingStrategy.new

    builder = Minitest::Mock.new
    builder.expect :mark_activity, nil
    builder.expect :to_h, { status: 'waiting' }

    emitted = []
    target_time = Time.now + 0.5
    strategy.stub :sleep, ->(_) { } do
      McptaskRunner::EventStream.stub :emit_snapshot, ->(snap, force: false) { emitted << [snap, force] } do
        strategy.send(:sleep_until, target_time, builder: builder)
      end
    end

    assert_equal 1, emitted.length
    assert_equal({ status: 'waiting' }, emitted[0][0])
    assert_equal true, emitted[0][1]
    builder.verify
  end

  def test_sleep_until_without_builder_skips_heartbeat
    strategy = McptaskRunner::WaitingStrategy.new

    emitted = []
    target_time = Time.now + 0.5
    strategy.stub :sleep, ->(_) { } do
      McptaskRunner::EventStream.stub :emit_snapshot, ->(snap, force: false) { emitted << snap } do
        strategy.send(:sleep_until, target_time)
      end
    end

    assert_empty emitted
  end
end
