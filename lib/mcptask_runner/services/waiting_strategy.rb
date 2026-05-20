# frozen_string_literal: true

module McptaskRunner
  # WaitingStrategy handles sleep periods between task batches based on different conditions
  class WaitingStrategy
    def wait_until_next_day(builder: nil)
      Logger.debug("[WaitingStrategy] [wait_until_next_day] Calculating next business day at 8 AM...")
      until_time = next_business_day_8am
      Logger.info_stdout("[WaitingStrategy] Next business day: #{until_time.strftime('%A, %Y-%m-%d at %H:%M')}")
      sleep_until(until_time, builder: builder)
    end

    def wait_one_hour(builder: nil)
      target_time = Time.now + 1.hour
      Logger.info_stdout("[WaitingStrategy] Waiting 1 hour before retry... (since #{Time.now.strftime('%H:%M')}, until #{target_time.strftime('%H:%M')})")
      Logger.debug("[WaitingStrategy] [wait_one_hour] Start time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")
      Logger.debug("[WaitingStrategy] [wait_one_hour] Resume time: #{target_time.strftime('%Y-%m-%d %H:%M:%S')}")
      sleep_until(target_time, builder: builder)
      Logger.debug("[WaitingStrategy] [wait_one_hour] 1 hour wait complete, ready to retry")
    end

    def wait_half_hour(builder: nil)
      target_time = Time.now + 30.minutes
      Logger.info_stdout("[WaitingStrategy] Waiting 30 minutes before retry... (since #{Time.now.strftime('%H:%M')}, until #{target_time.strftime('%H:%M')})")
      Logger.debug("[WaitingStrategy] [wait_half_hour] Start time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")
      Logger.debug("[WaitingStrategy] [wait_half_hour] Resume time: #{target_time.strftime('%Y-%m-%d %H:%M:%S')}")
      sleep_until(target_time, builder: builder)
      Logger.debug("[WaitingStrategy] [wait_half_hour] 30 minute wait complete, ready to retry")
    end

    private

    def sleep_until(until_time, builder: nil)
      Logger.debug("[WaitingStrategy] [sleep_until] Calculating sleep duration...")
      duration_seconds = until_time - Time.now

      if duration_seconds <= 0
        Logger.debug("[WaitingStrategy] [sleep_until] Target time already passed, no sleep needed")
        return
      end

      hours = (duration_seconds / 3600).round(2)
      Logger.info_stdout("[WaitingStrategy] Sleeping #{hours}h until #{until_time.strftime('%A, %Y-%m-%d at %H:%M:%S')}")
      Logger.debug("[WaitingStrategy] [sleep_until] Start time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")

      # Sleep in chunks and check wall-clock time to handle macOS sleep/suspend
      # correctly. A single long sleep() counts uptime, not wall-clock time.
      # Emit waiting-heartbeat snapshot per chunk so web UI doesn't infer a
      # frozen session from stale last_activity_at during long quiet waits.
      while Time.now < until_time
        remaining = until_time - Time.now
        sleep([remaining, 60].min)
        emit_wait_heartbeat(builder)
      end

      Logger.debug("[WaitingStrategy] [sleep_until] Sleep complete, woke up at #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")
    end

    def emit_wait_heartbeat(builder)
      return unless builder

      builder.mark_activity
      EventStream.emit_snapshot(builder.to_h, force: true)
    rescue StandardError => e
      Logger.debug("[WaitingStrategy] heartbeat emit failed: #{e.message}")
    end

    def next_business_day_8am
      Logger.debug("[WaitingStrategy] [next_business_day_8am] Finding next business day at 8 AM...")
      tomorrow = (Time.now + 1.day).beginning_of_day + 8.hours
      day_count = 1

      Logger.debug("[WaitingStrategy] [next_business_day_8am] Starting candidate: #{tomorrow.strftime('%A, %Y-%m-%d at %H:%M')} (wday=#{tomorrow.wday})")

      until working_day?(tomorrow)
        day_count += 1
        tomorrow += 1.day
        Logger.debug("[WaitingStrategy] [next_business_day_8am] Skipping weekend: #{tomorrow.strftime('%A, %Y-%m-%d')} (wday=#{tomorrow.wday})")
      end

      Logger.debug("[WaitingStrategy] [next_business_day_8am] Found business day after #{day_count} day(s): #{tomorrow.strftime('%A, %Y-%m-%d at %H:%M')}")
      tomorrow
    end

    def working_day?(date)
      is_working = date.wday != 0 && date.wday != 6 # not Sunday (0) or Saturday (6)
      day_name = date.strftime('%A')
      Logger.debug("[WaitingStrategy] [working_day?] Checking #{day_name} (wday=#{date.wday}): is_working_day=#{is_working}")
      is_working
    end
  end
end
