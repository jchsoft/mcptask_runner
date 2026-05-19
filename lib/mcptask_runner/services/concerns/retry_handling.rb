# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Manages retry logic for Claude execution: normal retries, marker retries, and API overload handling
    module RetryHandling
      MAX_RETRY_ATTEMPTS = 3
      MAX_API_OVERLOAD_RETRIES = 10 # API 529 errors are transient - retry more aggressively
      API_OVERLOAD_BASE_WAIT = 60   # base seconds to wait on API overload (doubles each retry)
      RETRY_WAIT_SECONDS = 30
      PRODUCTIVE_STREAM_THRESHOLD = 10 # stream events to consider a run "productive" (resets retry counter)

      RetryState = Struct.new(:count, :api_overload_count, :marker_retry_mode, keyword_init: true) do
        def self.initial
          new(count: 0, api_overload_count: 0, marker_retry_mode: false)
        end
      end

      private

      def run_with_retry(start_time)
        loop do
          overload_before = @retry_state.api_overload_count
          result = attempt_execution(start_time)
          return result if result

          # API overload retries are handled separately with their own counter and backoff
          next if @retry_state.api_overload_count > overload_before

          if @state.stream_line_count >= PRODUCTIVE_STREAM_THRESHOLD
            Logger.info_stdout "[#{@log_tag}] Claude was productive (#{@state.stream_line_count} stream events), resetting retry counter"
            @retry_state.count = 0
          else
            @retry_state.count += 1
          end
          break if @retry_state.count >= MAX_RETRY_ATTEMPTS

          Logger.info_stdout "[#{@log_tag}] Waiting #{RETRY_WAIT_SECONDS}s before retry #{@retry_state.count + 1}/#{MAX_RETRY_ATTEMPTS}..."
          sleep(RETRY_WAIT_SECONDS)
        end

        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)
        error_result("Claude execution failed after #{MAX_RETRY_ATTEMPTS} retry attempts (#{elapsed_hours} hours)")
      end

      def handle_recoverable_error(error_type, start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)

        if @retry_state.count >= MAX_RETRY_ATTEMPTS - 1
          Logger.error "[#{@log_tag}] #{error_type} - max retries reached"
          return error_result("#{error_type} after #{ClaudeCodeBase::INACTIVITY_TIMEOUT}s inactivity (#{elapsed_hours}h), retries exhausted")
        end

        Logger.warn "[#{@log_tag}] #{error_type} after #{elapsed_hours}h - will retry with --continue"
        nil # Signal to retry
      end

      def handle_marker_retry(start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)

        if @retry_state.count >= MAX_RETRY_ATTEMPTS - 1
          Logger.error "[#{@log_tag}] Missing marker - max retries reached"
          return error_result("Missing TASKRUNNER_RESULT after retries exhausted (#{elapsed_hours}h)")
        end

        Logger.warn "[#{@log_tag}] Missing TASKRUNNER_RESULT marker - will retry with marker-only instruction"
        @retry_state.marker_retry_mode = true
        nil # Signal to retry
      end

      def api_overload_detected?
        @state.api_overload ||
          @accumulated_output.include?('"error_status": 529') ||
          @accumulated_output.include?('Repeated 529 Overloaded') ||
          @accumulated_output.include?('"error_status":529')
      end

      def context_overflow_detected?
        @state.context_overflow ||
          @accumulated_output.include?('Prompt is too long') ||
          @accumulated_output.include?('prompt is too long') ||
          @accumulated_output.include?('context_length_exceeded')
      end

      def handle_context_overflow(start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)
        Logger.error "[#{@log_tag}] Context overflow — session unrecoverable after #{elapsed_hours}h, " \
                     'emitting terminal error (no --continue retry — it would hit the same limit)'
        error_result("Context overflow after #{elapsed_hours}h — session exceeded token limit, cannot resume with --continue")
          .merge('reason' => 'context_overflow')
      end

      # Stall is terminal for this run but the mcptask piece stays in_progress.
      # Status='stalled_for_opus' is intentionally NOT 'error' so Decider#tasks_failed?
      # does not break the WorkLoop — next triage iteration resumes with Opus.
      def handle_stalled(stall, start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)
        Logger.error "[#{@log_tag}] Stall terminal: #{stall.reason} (#{stall.count}×) sig=#{stall.signature} " \
                     "after #{elapsed_hours}h — task stays in_progress for Opus resume"
        {
          'status' => 'stalled_for_opus',
          'reason' => stall.reason.to_s,
          'signature' => stall.signature,
          'count' => stall.count,
          'detail' => stall.detail,
          'message' => "Stalled (#{stall.reason}); next triage will resume with Opus",
          'hours' => { 'task_worked' => elapsed_hours }
        }
      end

      def handle_api_overload(start_time)
        @retry_state.api_overload_count += 1
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)

        if @retry_state.api_overload_count >= MAX_API_OVERLOAD_RETRIES
          Logger.error "[#{@log_tag}] API overload - max retries (#{MAX_API_OVERLOAD_RETRIES}) reached after #{elapsed_hours}h"
          return error_result("API overloaded (529) after #{MAX_API_OVERLOAD_RETRIES} retries (#{elapsed_hours}h)")
        end

        wait_seconds = [API_OVERLOAD_BASE_WAIT * (2**([@retry_state.api_overload_count - 1, 3].min)), 600].min
        Logger.warn "[#{@log_tag}] API overloaded (529) - retry #{@retry_state.api_overload_count}/#{MAX_API_OVERLOAD_RETRIES}, " \
                    "waiting #{wait_seconds}s before next attempt..."
        sleep(wait_seconds)
        nil # Signal to retry (bypass normal retry counter)
      end

      def build_marker_retry_instructions
        original_instructions = build_instructions

        <<~INSTRUCTIONS
          Your previous session was interrupted before completing the workflow.

          Please:
          1. Check what you already completed (git status, git log, check for open PRs)
          2. Continue from where you left off in the workflow below
          3. Complete ALL remaining steps
          4. At the END, output the TASKRUNNER_RESULT marker as specified

          IMPORTANT: Do NOT just output the marker - first verify and complete any remaining work!

          === ORIGINAL WORKFLOW (continue from where you left off) ===

          #{original_instructions}
        INSTRUCTIONS
      end
    end
  end
end
