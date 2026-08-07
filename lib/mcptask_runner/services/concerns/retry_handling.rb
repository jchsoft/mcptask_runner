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
      MAX_OVERFLOW_RESTARTS = 1 # fresh-session restarts allowed on context overflow before terminal
      # Fresh-session restarts allowed when ReadMcpResourceTool reports "exists but is not enabled
      # in this context". Two root causes collapse to the same marker — (a) the mcptask-online SSE
      # server was still `pending` at fork startup, (b) the agent skipped the ToolSearch load step
      # for the deferred tool. Both are transient: a fresh child re-establishes the MCP connection
      # and re-receives the "FIRST call ToolSearch" instruction. With a ~30% per-attempt failure
      # rate observed in production logs, MAX_TOOL_NOT_ENABLED_RESTARTS=2 → 3 total attempts cuts
      # the death rate to ~0.3^3 ≈ 2.7%. See handle_tool_not_enabled.
      MAX_TOOL_NOT_ENABLED_RESTARTS = 2
      TOOL_NOT_ENABLED_RESTART_WAIT = 5 # seconds to let the old SSE connection release before refork

      RetryState = Struct.new(:count, :api_overload_count, :marker_retry_mode, :overflow_restart_count,
                              :tool_not_enabled_restart_count, :fresh_restart, keyword_init: true) do
        def self.initial
          new(count: 0, api_overload_count: 0, marker_retry_mode: false, overflow_restart_count: 0,
              tool_not_enabled_restart_count: 0, fresh_restart: false)
        end
      end

      private

      def run_with_retry(start_time)
        loop do
          overload_before = @retry_state.api_overload_count
          overflow_before = @retry_state.overflow_restart_count
          tool_not_enabled_before = @retry_state.tool_not_enabled_restart_count
          result = attempt_execution(start_time)
          return result if result

          # API overload retries are handled separately with their own counter and backoff
          next if @retry_state.api_overload_count > overload_before

          # Context-overflow fresh restart: own counter, must not burn a normal retry slot
          next if @retry_state.overflow_restart_count > overflow_before

          # Tool-not-enabled fresh restart: own counter, same rationale as overflow (see below)
          next if @retry_state.tool_not_enabled_restart_count > tool_not_enabled_before

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

      # Flag only — set by check_for_context_overflow (stream_processing.rb) which parses
      # the stream and fires solely on a genuine API error. A bare @accumulated_output
      # substring scan is a false-positive vector: any Grep/Read whose content quotes the
      # phrase (e.g. claude_code_base.rb's ContextOverflowError comment) would trip a
      # healthy session — exactly what killed a 30K-token run.
      def context_overflow_detected?
        @state.context_overflow
      end

      # Flag only — set by check_for_tool_not_enabled (stream_processing.rb) which parses
      # the stream and fires solely on a genuine is_error tool_result. A bare
      # @accumulated_output substring scan is a false-positive vector: any Grep/Read whose
      # content quotes the marker (e.g. tool_not_enabled_test.rb) would trip a healthy session.
      def tool_not_enabled_detected?
        @state.tool_not_enabled
      end

      # Context overflow is terminal for the bloated session — --continue would reload the same
      # oversized context and hit the limit again. But the work-in-progress lives on disk (git
      # branch + commits + logged task progress), so a FRESH session (no --continue) re-discovers
      # it and continues — the same recovery the next scheduled WorkLoop run would do, just now.
      # Capped at MAX_OVERFLOW_RESTARTS; a re-overflow after restart means the task is genuinely
      # too big → terminal.
      #
      # Either way the overflow is also persisted as a TaskHandoff note, because "terminal" only
      # ends THIS process: the piece stays in_progress, so a later runner cycle re-picks the same
      # task with empty context and would re-explore its way into the same wall. The note gives
      # that next attempt the on-disk state + a context budget (see #prior_overflow_preamble).
      #
      # Snapshot already emitted as :error by check_for_context_overflow; the restarted attempt
      # re-opens the card via reopen_snapshot_for_retry, so the web UI follows the live attempt
      # instead of freezing on the dead one.
      def handle_context_overflow(start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)

        if @retry_state.overflow_restart_count >= MAX_OVERFLOW_RESTARTS
          Logger.error "[#{@log_tag}] Context overflow again after fresh restart (#{elapsed_hours}h) — " \
                       'session unrecoverable, emitting terminal error'
          message = "Context overflow after #{elapsed_hours}h — fresh restart also overflowed, task exceeds token limit"
          record_task_handoff(start_time, terminal: true, message: message)
          return error_result(message).merge('reason' => 'context_overflow')
        end

        record_task_handoff(start_time, terminal: false, message: "Context overflow after #{elapsed_hours}h — restarting fresh")

        @retry_state.overflow_restart_count += 1
        @retry_state.fresh_restart = true
        @accumulated_output = ''.dup
        @text_content = ''.dup
        Logger.warn "[#{@log_tag}] Context overflow after #{elapsed_hours}h — restarting in a FRESH session " \
                    "(no --continue) to recover on-disk work (restart #{@retry_state.overflow_restart_count}/#{MAX_OVERFLOW_RESTARTS})"
        nil # Signal to retry with a fresh session
      end

      # ReadMcpResourceTool reported "exists but is not enabled in this context". Two transient
      # causes collapse to that marker: (a) the mcptask-online SSE server was still `pending` at
      # fork startup (documented SSE race in config/skills/mcptask-read/SKILL.md), or (b) the
      # agent skipped the ToolSearch load step for the deferred tool. Both recover with a FRESH
      # session — a new child re-establishes the MCP connection and re-receives the "FIRST call
      # ToolSearch" instruction. This is NOT a mid-session server drop (the server/token are
      # fine — production logs show ~70% of triage calls succeed against the same endpoint), so
      # --continue would just re-emit the same failure; a fresh session is the correct recovery,
      # mirroring handle_context_overflow. Capped at MAX_TOOL_NOT_ENABLED_RESTARTS.
      #
      # Snapshot already emitted as :error by check_for_tool_not_enabled in stream_processing.rb
      # (mirrors check_stall); the retried attempt re-opens the card via reopen_snapshot_for_retry.
      def handle_tool_not_enabled(start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)

        if @retry_state.tool_not_enabled_restart_count >= MAX_TOOL_NOT_ENABLED_RESTARTS
          message = "MCP tool not enabled after #{elapsed_hours}h — fresh restarts exhausted " \
                    "(#{MAX_TOOL_NOT_ENABLED_RESTARTS}), ReadMcpResourceTool never loaded " \
                    '(deferred tool / SSE startup race), session cannot recover'
          Logger.error "[#{@log_tag}] #{message}"
          return error_result(message).merge('reason' => 'tool_not_enabled')
        end

        @retry_state.tool_not_enabled_restart_count += 1
        @retry_state.fresh_restart = true
        @accumulated_output = ''.dup
        @text_content = ''.dup
        Logger.warn "[#{@log_tag}] MCP tool not enabled after #{elapsed_hours}h — restarting in a FRESH " \
                     "session (no --continue) to re-establish the MCP connection / re-load the deferred tool " \
                     "(restart #{@retry_state.tool_not_enabled_restart_count}/#{MAX_TOOL_NOT_ENABLED_RESTARTS})"
        sleep(TOOL_NOT_ENABLED_RESTART_WAIT)
        nil # Signal to retry with a fresh session
      end

      # Stall is terminal for this run but the mcptask piece stays in_progress.
      # Status='stalled_for_genius' is intentionally NOT 'error' so Decider#tasks_failed?
      # does not break the WorkLoop — next triage iteration resumes with genius.
      def handle_stalled(stall, start_time)
        elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)
        Logger.error "[#{@log_tag}] Stall terminal: #{stall.reason} (#{stall.count}×) sig=#{stall.signature} " \
                     "after #{elapsed_hours}h — task stays in_progress for genius resume"
        {
          'status' => 'stalled_for_genius',
          'reason' => stall.reason.to_s,
          'signature' => stall.signature,
          'count' => stall.count,
          'detail' => stall.detail,
          'message' => "Stalled (#{stall.reason}); next triage will resume with genius",
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

      # Sent on every --continue retry (marker-retry OR recoverable-error retry). The resumed
      # session already carries the full original workflow in context, so we deliberately do NOT
      # re-send build_instructions — that would just duplicate the branch/implement/test steps that
      # are already done and already in context. We re-state only the result-format contract (the one
      # thing whose omission triggers marker-retry) and reference the rest of the workflow above.
      def build_continuation_instructions
        <<~INSTRUCTIONS
          Your previous session was interrupted before completing the workflow or before emitting the result marker.
          The full workflow is already in this conversation above — it is NOT repeated here.

          Please:
          1. Check what you already completed (git status, git log, check for open PRs)
          2. Continue from where you left off in the workflow above
          3. Complete ALL remaining steps
          4. At the END, output the TASKRUNNER_RESULT marker as specified

          IMPORTANT: Do NOT just output the marker - first verify and complete any remaining work!

          #{continuation_result_contract}
        INSTRUCTIONS
      end

      # Result-format contract re-stated on continuation. Default is a generic reference (the exact
      # format is in the resumed context). auto_squash_base overrides this to reproduce the full
      # contract block via result_format_instruction.
      def continuation_result_contract
        'Output TASKRUNNER_RESULT exactly in the JSON format specified earlier in this conversation.'
      end
    end
  end
end
