# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Quota checking, time-of-day guards, and daily scheduling logic
    module QuotaScheduling
      private

      def quota_exceeded?(results)
        if @ignore_quota
          Logger.debug('[WorkLoop] [quota_exceeded?] Quota check skipped (ignore_quota: true)')
          return false
        end

        decider = Decider.new(task_results: results)
        exceeded = decider.should_stop?
        Logger.info_stdout('[WorkLoop] Quota exceeded, stopping') if exceeded
        exceeded
      end

      def should_stop_running_today?(results)
        end_of_day? || quota_exceeded?(results)
      end

      def no_tasks_available?(result)
        result['status'] == 'no_more_tasks'
      end

      def end_of_day?
        Time.now.hour >= 23
      end

      def end_of_workday?
        Time.now.hour >= 18
      end

      def wait_if_cannot_work_today
        return if DailyScheduler.new(task_results: []).can_work_today?

        Logger.info_stdout('[WorkLoop] Cannot work today (quota is 0 or weekend), waiting until next business day...')
        WaitingStrategy.new.wait_until_next_day(builder: @builder)
      end

      def handle_no_tasks_with_wait(wait_method, mode_label)
        if end_of_workday?
          Logger.info_stdout("[WorkLoop] Past end of workday (18:00), stopping #{mode_label}")
          return false
        end

        WaitingStrategy.new.send(wait_method, builder: @builder)

        if end_of_workday?
          Logger.info_stdout("[WorkLoop] Now past end of workday (18:00), stopping #{mode_label}")
          return false
        end

        true
      end

      def handle_no_tasks_in_today_auto_squash_mode
        handle_no_tasks_with_wait(:wait_half_hour, 'today auto-squash')
      end

      def handle_no_tasks_in_daily_mode
        handle_no_tasks_with_wait(:wait_one_hour, 'daily mode')
      end

      def handle_daily_completion(daily_results)
        scheduler = DailyScheduler.new(task_results: daily_results)
        return if scheduler.should_continue_working?

        Logger.info_stdout('[WorkLoop] Daily quota exceeded, waiting until next day...')
        WaitingStrategy.new.wait_until_next_day(builder: @builder)
      end
    end
  end
end
