# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # All iteration loop strategies: once, today, daily, story, queue, reviews, workflow
    # Each run_* method orchestrates a specific execution pattern
    module LoopStrategies
      private

      # --- Single execution modes ---

      def run_once
        triage_and_execute(ClaudeCode::Honest)
      end

      def run_once_auto_squash
        triage_and_execute(ClaudeCode::OnceAutoSquash)
      end

      def run_once_dry
        result = ClaudeCode::Dry.new(verbose: @verbose).run
        Logger.info_stdout("[WorkLoop] Dry-run completed with status: #{result['status']}")
        result
      end

      def run_review
        result = ClaudeCode::Review.new(verbose: @verbose).run
        Logger.info_stdout("[WorkLoop] Review completed with status: #{result['status']}")
        result
      end

      def run_task_manual
        raise ArgumentError, 'task_id is required for task_manual mode' unless @task_id

        triage_and_execute(ClaudeCode::TaskManual, task_id: @task_id)
      end

      def run_task_auto_squash
        raise ArgumentError, 'task_id is required for task_auto_squash mode' unless @task_id

        triage_and_execute(ClaudeCode::TaskAutoSquash, task_id: @task_id)
      end

      # --- Multi-iteration loops ---

      def run_reviews
        results = []
        iteration_count = 0

        loop do
          iteration_count += 1
          result = ClaudeCode::Reviews.new(verbose: @verbose).run
          results << result
          Logger.info_stdout("[WorkLoop] Review ##{iteration_count} completed with status: #{result['status']}")

          break if result['status'] == 'no_reviews'
          break if result['status'] == 'failure'
          break if quota_exceeded?(results)

          sleep(2)
        end

        Logger.info_stdout("[WorkLoop] Reviews loop complete, total processed: #{results.length}")
        results
      end

      def run_workflow
        workflow_results = { 'reviews' => [], 'tasks' => [] }

        Logger.info_stdout('[WorkLoop] Phase 1: Processing PR reviews...')
        workflow_results['reviews'] = run_reviews

        Logger.info_stdout('[WorkLoop] Phase 2: Processing tasks for today...')
        workflow_results['tasks'] = run_today

        Logger.info_stdout("[WorkLoop] Workflow complete: #{workflow_results['reviews'].length} reviews, #{workflow_results['tasks'].length} tasks")
        workflow_results
      end

      def run_story_manual
        raise ArgumentError, 'story_id is required for story_manual mode' unless @story_id

        results = []
        iteration_count = 0

        loop do
          iteration_count += 1
          result = triage_and_execute(ClaudeCode::StoryManual, story_id: @story_id, skip_story_load: iteration_count > 1)
          results << result
          Logger.info_stdout("[WorkLoop] Task ##{iteration_count} completed with status: #{result['status']}")

          if result['status'] == 'urgent_bug_pending'
            Logger.info_stdout("[WorkLoop] Urgent bug ##{result['bug_task_id']} pending — exiting story manual loop")
            break
          end

          if result['status'] == 'urgent_bug_pending_dirty_branch'
            Logger.error("[WorkLoop] Cannot proceed — branch '#{result['dirty_branch']}' has uncommitted changes; manual cleanup required")
            break
          end

          break if %w[no_more_tasks failure task_already_started quota_exceeded quota_exceeded_mid_task].include?(result['status'])
          break if quota_exceeded?(results)

          sleep(2)
        end

        Logger.info_stdout("[WorkLoop] Story manual workflow complete, total tasks processed: #{results.length}")
        results
      end

      def run_story_auto_squash
        raise ArgumentError, 'story_id is required for story_auto_squash mode' unless @story_id

        run_auto_squash_loop('Story auto-squash', ClaudeCode::StoryAutoSquash) do |iteration_count|
          { story_id: @story_id, skip_story_load: iteration_count > 1 }
        end
      end

      def run_today_auto_squash
        run_auto_squash_loop('Today auto-squash', ClaudeCode::TodayAutoSquash, handle_no_tasks: true)
      end

      def run_queue_auto_squash
        run_auto_squash_loop('Queue auto-squash', ClaudeCode::QueueAutoSquash)
      end

      def run_queue_manual
        results = []
        iteration_count = 0

        loop do
          iteration_count += 1
          result = triage_and_execute(ClaudeCode::Honest)
          results << result
          Logger.info_stdout("[WorkLoop] Task ##{iteration_count} completed with status: #{result['status']}")

          break if %w[no_more_tasks failure quota_exceeded quota_exceeded_mid_task urgent_bug_pending_dirty_branch].include?(result['status'])
          break if quota_exceeded?(results)

          sleep(2)
        end

        Logger.info_stdout("[WorkLoop] Queue manual workflow complete, total tasks processed: #{results.length}")
        results
      end

      def run_today
        results = []
        iteration_count = 0

        loop do
          iteration_count += 1
          result = triage_and_execute(ClaudeCode::Honest)
          results << result
          Logger.info_stdout("[WorkLoop] Task ##{iteration_count} completed with status: #{result['status']}")

          break if no_tasks_available?(result) || %w[quota_exceeded quota_exceeded_mid_task urgent_bug_pending_dirty_branch].include?(result['status'])
          break if should_stop_running_today?(results)

          sleep(2)
        end

        Logger.info_stdout("[WorkLoop] Today's execution complete, total tasks: #{results.length}")
        results
      end

      def run_daily
        Logger.info_stdout('[WorkLoop] Starting daily execution loop...')
        day_count = 0

        loop do
          day_count += 1
          wait_if_cannot_work_today
          daily_results = run_today_tasks
          Logger.info_stdout("[WorkLoop] Day ##{day_count} completed with #{daily_results.length} tasks")
          handle_daily_completion(daily_results)
        end
      end

      def run_today_tasks
        results = []
        iteration_count = 0

        loop do
          iteration_count += 1
          result = triage_and_execute(ClaudeCode::Honest)
          results << result

          break if %w[quota_exceeded quota_exceeded_mid_task urgent_bug_pending_dirty_branch].include?(result['status'])

          if no_tasks_available?(result)
            break if !@ignore_quota && QuotaGuard.exceeded?

            Logger.info_stdout('[WorkLoop] No tasks available, will wait 1 hour before retry...')
            break unless handle_no_tasks_in_daily_mode

            next
          end

          break if should_stop_running_today?(results)

          sleep(2)
        end

        results
      end

      def run_story_loop(story_id, original_executor_class, model_override: nil, first_task_id: nil)
        story_executor = story_executor_for(original_executor_class)
        Logger.info_stdout("[WorkLoop] Story loop: using #{story_executor.name} (mapped from #{original_executor_class.name})")
        results = []
        iteration_count = 0

        loop do
          iteration_count += 1

          result = if iteration_count == 1 && first_task_id
            executor = story_executor.new(story_id: story_id, task_id: first_task_id, verbose: @verbose,
                                          model_override: model_override, snapshot_builder: @builder)
            run_with_quota_guard(executor, first_task_id)
          else
            triage_and_execute(story_executor, story_id: story_id, skip_story_load: true)
          end

          results << result
          status = result['status']
          Logger.info_stdout("[WorkLoop] Story loop task ##{iteration_count} completed with status: #{status}")

          if status == 'preexisting_test_errors'
            sleep(2)
            next
          end

          if status == 'already_done'
            Logger.info_stdout('[WorkLoop] Task already resolved (no code changes needed), continuing to next task...')
            sleep(2)
            next
          end

          if status == 'urgent_bug_pending'
            Logger.info_stdout("[WorkLoop] Urgent bug ##{result['bug_task_id']} pending — exiting story loop, parent will re-triage")
            break
          end

          if status == 'urgent_bug_pending_dirty_branch'
            Logger.error("[WorkLoop] Cannot proceed — branch '#{result['dirty_branch']}' has uncommitted changes; manual cleanup required")
            break
          end

          break if %w[no_more_tasks failure task_already_started ci_failed merge_failed merge_unverified quota_exceeded quota_exceeded_mid_task].include?(status)
          break if quota_exceeded?(results)

          sleep(2)
        end

        Logger.info_stdout("[WorkLoop] Story loop complete for Story ##{story_id}, total tasks: #{results.length}")
        results.last || { 'status' => 'no_more_tasks' }
      end

      # --- Shared helper for auto-squash loops ---

      def run_auto_squash_loop(label, executor_class, handle_no_tasks: false)
        results = []
        iteration_count = 0

        loop do
          iteration_count += 1
          extra_kwargs = block_given? ? yield(iteration_count) : {}
          result = triage_and_execute(executor_class, **extra_kwargs)
          results << result
          status = result['status']
          Logger.info_stdout("[WorkLoop] #{label} ##{iteration_count} completed with status: #{status}")

          if status == 'no_more_tasks' && handle_no_tasks
            break if !@ignore_quota && QuotaGuard.exceeded?
            break unless handle_no_tasks_in_today_auto_squash_mode

            next
          end

          if status == 'preexisting_test_errors'
            Logger.info_stdout('[WorkLoop] Preexisting test errors detected, continuing to next task...')
            sleep(2)
            next
          end

          if status == 'already_done'
            Logger.info_stdout('[WorkLoop] Task already resolved (no code changes needed), continuing to next task...')
            sleep(2)
            next
          end

          if status == 'urgent_bug_pending'
            if @story_id
              Logger.info_stdout("[WorkLoop] Urgent bug ##{result['bug_task_id']} pending — exiting #{label} loop")
              break
            end

            Logger.info_stdout("[WorkLoop] Urgent bug ##{result['bug_task_id']} pending — re-triaging globally")
            sleep(2)
            next
          end

          if status == 'urgent_bug_pending_dirty_branch'
            Logger.error("[WorkLoop] Cannot proceed — branch '#{result['dirty_branch']}' has uncommitted changes; manual cleanup required")
            break
          end

          break if %w[no_more_tasks failure task_already_started ci_failed merge_failed merge_unverified quota_exceeded quota_exceeded_mid_task].include?(status)
          break if quota_exceeded?(results)

          sleep(2)
        end

        Logger.info_stdout("[WorkLoop] #{label} complete, total processed: #{results.length}")
        results
      end
    end
  end
end
