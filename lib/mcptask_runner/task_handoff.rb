# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'open3'

module McptaskRunner
  # Cross-run handoff note for a task whose Claude session died of context overflow.
  #
  # RetryHandling#handle_context_overflow already recovers *within* one runner process: it
  # restarts the child in a fresh session (see MAX_OVERFLOW_RESTARTS). When that restart
  # overflows too, the run ends terminal — but the mcptask piece stays in_progress, so the NEXT
  # runner cycle (new process, minutes or hours later) re-picks the same task, starts from zero
  # context, repeats the same wasteful exploration and overflows again. Nothing about the failed
  # attempt survives the process boundary, so the loop is invisible from inside the prompt.
  #
  # This store is that survivor: one small JSON note per task under log/handoffs/, written the
  # moment an overflow is detected and read back when the same task_id shows up in a later run.
  # Concerns::OverflowHandoff turns it into a prompt preamble (#preamble) so the next child is a
  # told it is a repeat attempt, where the on-disk work is, what the dead session was doing, and
  # that context — not difficulty — is what it has to budget for.
  #
  # Every write is best-effort and rescue-guarded: a handoff-logging failure must NEVER break a
  # run (same contract as RunLog).
  class TaskHandoff
    HANDOFFS_DIR = File.join('log', 'handoffs').freeze

    # Notes for tasks nobody came back to are pruned on write, so an abandoned task can't nag a
    # future run forever.
    MAX_AGE_DAYS = 30

    MAX_LISTED_FILES = 12
    MAX_LISTED_COMMITS = 8
    MAX_LISTED_TODOS = 6

    # The attempt that just died. Bundled so record_overflow reads as one intent instead of a
    # six-slot signature; everything else (task name, model, todos, last message) is read off the
    # SnapshotBuilder, which already tracks it for the dashboard.
    Overflow = Data.define(:task_id, :mode, :elapsed_s, :terminal, :message)

    class << self
      # Opt-out only, mirroring RunLog.enabled? (tests that must not touch disk set it to 0).
      def enabled?
        ENV['MCPTASK_TASK_HANDOFF'] != '0'
      end

      def path_for(task_id)
        File.join(HANDOFFS_DIR, "task_#{task_id}.json")
      end

      # The note for task_id, or nil when there is none — the normal case.
      def load(task_id)
        return nil unless enabled? && task_id

        path = path_for(task_id)
        return nil unless File.exist?(path)

        new(JSON.parse(File.read(path)))
      rescue StandardError => e
        Logger.warn "[TaskHandoff] read failed for ##{task_id}: #{e.message}"
        nil
      end

      # Append one overflow observation for overflow.task_id. overflow_count accumulates across
      # runner processes, so a task that keeps blowing the context is visible as such in the next
      # prompt even though each process starts with a fresh RetryState.
      def record_overflow(overflow, builder)
        return nil unless enabled? && overflow.task_id

        data = overflow_data(overflow, builder)
        write(overflow.task_id, data)
        prune_stale
        new(data)
      rescue StandardError => e
        Logger.warn "[TaskHandoff] record failed for ##{overflow.task_id}: #{e.message}"
        nil
      end

      # Drop the note: the task either finished or completed a run without overflowing, so a
      # future attempt must not be told it is a repeat.
      def clear(task_id)
        return unless task_id

        path = path_for(task_id)
        File.delete(path) if File.exist?(path)
      rescue StandardError => e
        Logger.warn "[TaskHandoff] clear failed for ##{task_id}: #{e.message}"
      end

      private

      def overflow_data(overflow, builder)
        previous = load(overflow.task_id)&.data || {}
        snapshot = builder.to_h
        {
          'task_id' => overflow.task_id,
          'task_name' => snapshot[:task_name] || previous['task_name'],
          'mode' => overflow.mode,
          'model' => snapshot[:model] || previous['model'],
          'overflow_count' => previous.fetch('overflow_count', 0) + 1,
          'terminal' => overflow.terminal,
          'last_error' => overflow.message,
          'elapsed_s' => overflow.elapsed_s.round(1),
          'recent_actions' => builder.recent_actions,
          'open_todos' => open_todos(snapshot),
          'last_message' => snapshot[:message],
          'first_overflow_at' => previous['first_overflow_at'] || iso_now,
          'updated_at' => iso_now
        }.merge(git_state)
      end

      def open_todos(snapshot)
        Array(snapshot[:todo_list]).reject { |todo| todo[:status] == 'completed' }
                                   .map { |todo| todo[:content] }
                                   .first(MAX_LISTED_TODOS)
      end

      # What the dead session left on disk. This is the part a fresh child cannot guess and the
      # part that makes re-exploration unnecessary.
      def git_state
        {
          'branch' => git_line('branch', '--show-current'),
          'commits' => git_lines('log', '--oneline', '-n', MAX_LISTED_COMMITS.to_s, 'origin/main..HEAD'),
          'uncommitted' => git_lines('status', '--porcelain').first(MAX_LISTED_FILES)
        }
      end

      def git_line(*args)
        git_lines(*args).first.to_s
      end

      def git_lines(*args)
        out, status = Open3.capture2('git', *args, err: File::NULL)
        status.success? ? out.lines.map(&:strip).reject(&:empty?) : []
      rescue StandardError
        []
      end

      def write(task_id, data)
        FileUtils.mkdir_p(HANDOFFS_DIR)
        File.write(path_for(task_id), JSON.pretty_generate(data))
      end

      def prune_stale
        cutoff = Time.now - (MAX_AGE_DAYS * 86_400)
        Dir.glob(File.join(HANDOFFS_DIR, 'task_*.json')).each do |path|
          File.delete(path) if File.mtime(path) < cutoff
        end
      rescue StandardError => e
        Logger.warn "[TaskHandoff] prune failed: #{e.message}"
      end

      def iso_now
        Time.now.utc.iso8601(3)
      end
    end

    attr_reader :data

    def initialize(data)
      @data = data
    end

    def overflow_count
      @data.fetch('overflow_count', 0)
    end

    # Prompt block prepended ahead of the full workflow when a LATER runner process picks up this
    # same task. Two jobs: point at the on-disk work so nothing is redone, and spell out the
    # context budget — the previous attempts didn't fail on difficulty, they ran out of room.
    def preamble
      <<~PREAMBLE
        [REPEAT ATTEMPT — #{attempt_count_phrase} on this task died with "Prompt is too long" (context overflow)]
        #{last_attempt_line}
        #{state_lines}
        CONTEXT BUDGET (mandatory — here the blocker is context, not difficulty):
        - Start from `git status` and `git log --oneline origin/main..HEAD` on that branch, plus the task's
          own progress log in mcptask. Do NOT re-explore the codebase from zero.
        - Read with offset/limit or `grep -n`; never dump a whole file over 200 lines, never run
          `find`/`grep -r` without a path filter, never `Read` a .png/screenshot (base64 counts as text,
          ~150K tokens). Never re-read a file you already read, and never poll in a loop.
        - Log progress to mcptask as you go — that log is the only state the NEXT attempt inherits.
        - If the remaining work still will not fit: SHRINK IT. Implement the smallest complete, mergeable
          slice, PR that, and record what is left in the task's progress log.

      PREAMBLE
    end

    private

    def attempt_count_phrase
      overflow_count == 1 ? 'a previous session' : "#{overflow_count} previous sessions"
    end

    def last_attempt_line
      details = ["last: #{@data['updated_at']}"]
      details << "#{@data['elapsed_s']}s" if @data['elapsed_s']
      details << "model #{@data['model']}" if @data['model']
      details << "mode #{@data['mode']}" if @data['mode']
      "Previous attempt (#{details.join(', ')}) ran out of context before finishing. Its work is on disk:"
    end

    # Only the facts we actually have — an empty branch/commit list must not leave a dangling label.
    def state_lines
      [
        labelled('branch', @data['branch']),
        labelled('commits on branch', Array(@data['commits']).join(' | ')),
        labelled('uncommitted', Array(@data['uncommitted']).join(', ')),
        labelled('last actions before dying', Array(@data['recent_actions']).join(' | ')),
        labelled('unfinished plan', Array(@data['open_todos']).join('; ')),
        labelled('last words', @data['last_message'])
      ].compact.join("\n")
    end

    def labelled(label, value)
      text = value.to_s.strip
      text.empty? ? nil : "- #{label}: #{truncate(text)}"
    end

    def truncate(text)
      clean = text.tr("\n\r\t", ' ').squeeze(' ')
      clean.length > 300 ? "#{clean[0, 297]}..." : clean
    end
  end
end
