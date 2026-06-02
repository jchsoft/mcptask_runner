# frozen_string_literal: true

module McptaskRunner
  # Working-day availability + daily quota for the looping modes. Both questions
  # are answered from QuotaGuard (REST), never from AI-agent self-report.
  #
  # Fail directions differ on purpose:
  # - "is quota exceeded?" → fail-closed (a REST blip stops new work, never overruns)
  # - "can I work today?"  → fail-open (a REST blip must NOT condemn the whole day to
  #   wait_until_next_day; the quota gate still protects against overrun, and per_day==0
  #   holidays are caught by `quota_exceeded?` anyway)
  class DailyScheduler
    def initialize(task_results: [])
      @task_results = task_results.is_a?(Hash) ? [task_results] : task_results
    end

    def can_work_today?
      status = QuotaGuard.status
      return true unless status.rest_ok

      can_work = status.per_day.positive?
      Logger.debug("[DailyScheduler] [can_work_today?] per_day: #{status.per_day}h, can_work: #{can_work}")
      can_work
    end

    def should_continue_working?
      !QuotaGuard.exceeded?
    end

    def wait_reason
      status = QuotaGuard.status
      return :zero_quota if status.rest_ok && !status.per_day.positive?
      return :quota_exceeded if status.exceeded

      nil
    end
  end
end
