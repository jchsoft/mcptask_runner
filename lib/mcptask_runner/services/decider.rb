# frozen_string_literal: true

module McptaskRunner
  # Between-task stop decision. Daily quota comes straight from QuotaGuard (REST,
  # no AI self-report); the task-result statuses are the runner's own signal.
  class Decider
    def initialize(task_results: [])
      Logger.debug("[Decider] [initialize] Initializing with #{task_results.length} task results")
      @task_results = task_results.is_a?(Hash) ? [task_results] : task_results
    end

    def should_continue?
      !should_stop?
    end

    def should_stop?
      return true if tasks_failed? || quota_exceeded_mid_task?

      daily_quota_exceeded?
    end

    def quota_exceeded_mid_task?
      hit = @task_results.any? { |r| r['status'] == 'quota_exceeded_mid_task' }
      Logger.debug("[Decider] [quota_exceeded_mid_task?] hit: #{hit}")
      hit
    end

    def summary
      status = QuotaGuard.status
      {
        should_continue: !(tasks_failed? || quota_exceeded_mid_task? || status.exceeded),
        remaining_hours: status.rest_ok ? (status.per_day - status.worked_today).round(2) : nil,
        tasks_completed: tasks_completed,
        tasks_failed: tasks_failed?,
        daily_limit: status.per_day,
        total_worked: status.worked_today
      }
    end

    private

    # No task results yet (loop hasn't completed a task) → nothing to stop for.
    # Once work exists, the live REST quota is authoritative.
    def daily_quota_exceeded?
      return false if @task_results.empty?

      QuotaGuard.exceeded?
    end

    def tasks_failed?
      failed_count = @task_results.count { |r| r['status'] == 'error' }
      Logger.debug("[Decider] [tasks_failed?] Total: #{@task_results.length}, failed: #{failed_count}")
      failed_count.positive?
    end

    def tasks_completed
      @task_results.count { |r| r['status'] == 'success' }
    end
  end
end
