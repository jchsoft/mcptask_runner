# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Everything the executor does to survive a context overflow: the in-process fresh-restart
    # handoff (live action trail) and the cross-process one (TaskHandoff note on disk), plus the
    # single decision of which — if either — gets prepended to an attempt's instructions.
    module OverflowHandoff
      private

      # Extra text ahead of the workflow. A fresh restart after an in-process overflow gets the
      # live action trail; the first attempt of a NEW runner process gets the on-disk note left by
      # an earlier process that overflowed on this same task. A --continue retry gets neither — the
      # resumed session already carries everything in context, and re-stating it would re-bloat the
      # very context we are recovering from. Never both: they say the same thing twice.
      def attempt_preamble(fresh:, continue:)
        return fresh_restart_preamble if fresh
        return '' if continue

        prior_overflow_preamble
      end

      # Handoff for a fresh-session restart after a context overflow. The dead session's work lives
      # on disk (git branch + commits), but the new child starts with empty context and no memory of
      # what it was mid-doing — so prepend its last few actions plus a nudge to work lean. Empty when
      # there's nothing to hand off (e.g. overflow before any tool ran), keeping normal runs untouched.
      def fresh_restart_preamble
        actions = @snapshot_builder.recent_actions
        return '' if actions.empty?

        numbered = actions.each_with_index.map { |action, i| "#{i + 1}. #{action}" }.join("\n")
        <<~PREAMBLE
          Your previous session ran out of context and was restarted fresh. Your work so far is on disk
          (git branch + commits) — run `git status` / `git log` first to see it. The last #{actions.size} actions you
          performed were:
          #{numbered}
          Continue from there. Work in a focused way — read only the lines you need and avoid dumping whole
          files or unbounded `find`/`grep` output, so you don't run out of context again.

        PREAMBLE
      end

      # Prompt preamble for a task that already overflowed in an EARLIER runner process. Empty
      # string when there is no note — the normal case, so ordinary runs are untouched.
      def prior_overflow_preamble
        TaskHandoff.load(@task_id)&.preamble.to_s
      end

      # Persist the overflow as a cross-run note for @task_id, so the next runner process that picks
      # this task up is told it is a repeat attempt instead of re-exploring into the same wall.
      # Called from RetryHandling#handle_context_overflow on both the restart and terminal branch.
      def record_task_handoff(start_time, terminal:, message:)
        TaskHandoff.record_overflow(
          TaskHandoff::Overflow.new(task_id: @task_id, mode: @log_tag, elapsed_s: Time.now - start_time,
                                    terminal: terminal, message: message),
          @snapshot_builder
        )
      end

      # Drop the note once a run ends on anything other than a context-overflow terminal: the task
      # either finished or at least got through a session without blowing up, so telling a future
      # attempt "you are a repeat" would be stale noise.
      def finalize_task_handoff(result)
        TaskHandoff.clear(@task_id) unless result['reason'] == 'context_overflow'
      end
    end
  end
end
