# frozen_string_literal: true

require 'digest'
require 'json'

module McptaskRunner
  # Detects when a Claude session is spinning without progress.
  # Fed line-by-line from the stdout stream thread via #observe_tool_use / #observe_tool_result.
  # Returns a Stall struct (or nil) — caller is responsible for killing the subprocess and
  # raising the terminal error. Pure data; no IO, no threading, no Claude knowledge.
  #
  # Composes with TriageExecution#upgrade_model_for_resume — a stalled run terminates with
  # status='stalled_for_genius' and the task stays in_progress in mcptask, so the next triage
  # picks it up as resuming=true and forces genius.
  class StallDetector
    Stall = Struct.new(:reason, :signature, :count, :detail, keyword_init: true)

    EDIT_FAILURE_STREAK_LIMIT = 3
    BASH_FAILURE_REPEAT_LIMIT = 3
    SIGNATURE_REPEAT_LIMIT    = 4
    WINDOW_SIZE               = 12

    MUTATING_TOOLS = %w[Edit Write NotebookEdit].freeze
    # Polling helpers — same-input re-invocation is by design (poll CI/test/lock until done).
    # Excluded from loop_signature detection or every CI wait > 4 invocations would false-positive.
    # ALL Skill calls are treated as polling: Skill is a dispatch to a sub-routine, not a unit of
    # work itself. Same skill invoked 4× is not a stall — it's the agent legitimately dispatching
    # the same skill with the same args. Genuine hangs inside a Skill are caught by the hung_tool
    # watchdog (TOOL_HANG_TIMEOUTS long kill = 2700s). The historical 4× same-skill kill had no
    # real stall signal — it just murdered agents that were working normally.
    POLLING = {
      skills: :all, # every Skill invocation is exempt from loop_signature detection
      bash_re: %r{\.claude/bin/(?:ci_wait|test_wait|wait_unlock)\b}.freeze
    }.freeze

    def initialize(log_tag)
      @log_tag = log_tag
      @edit_failure_streak = 0
      @bash_failures = Hash.new { |h, sig| h[sig] = { exit_code: nil, count: 0 } }
      @pending = {}                  # tool_use_id -> { name:, signature: }
      @signature_window = []         # ring of { signature:, mutated_after: false }
      @file_mutated_during_window = false
      @mutation_since_last_bash = false # progress guard for bash_failure_loop
    end

    def observe_tool_use(item)
      name = item['name']
      input = item['input'] || {}
      return nil if polling_call?(name, input)

      sig = signature_for(name, input)
      @pending[item['id']] = { name: name, signature: sig }

      push_signature(sig)
      detect_signature_repeat(sig)
    end

    def observe_tool_result(item)
      pending = @pending.delete(item['tool_use_id']) or return nil
      is_error = item['is_error'] == true

      case pending[:name]
      when *MUTATING_TOOLS then on_mutating_result(pending, is_error)
      when 'Bash'          then on_bash_result(pending, item, is_error)
      end
    end

    private

    def polling_call?(name, input)
      case name
      when 'Skill' then POLLING[:skills] == :all # every Skill invocation is exempt
      when 'Bash'  then input['command'].to_s.match?(POLLING[:bash_re])
      end
    end

    def on_mutating_result(pending, is_error)
      if is_error
        @edit_failure_streak += 1
        return stall(:edit_failures, pending[:signature], @edit_failure_streak) if @edit_failure_streak >= EDIT_FAILURE_STREAK_LIMIT
      else
        @edit_failure_streak = 0
        @file_mutated_during_window = true
        @mutation_since_last_bash = true
      end
      nil
    end

    def on_bash_result(pending, item, is_error)
      exit_code = parse_bash_exit_code(item)
      record = @bash_failures[pending[:signature]]

      # Non-error, non-zero exit codes still count as "stuck" (e.g. tests keep failing on same cmd).
      # A successful edit since the last bash result means progress happened — reset, not a stall.
      # Mirrors the @file_mutated_during_window guard in detect_signature_repeat.
      if (is_error || (exit_code && exit_code != 0)) && record[:exit_code] == exit_code && !@mutation_since_last_bash
        record[:count] += 1
        return stall(:bash_failure_loop, pending[:signature], record[:count], "exit=#{exit_code}") if record[:count] >= BASH_FAILURE_REPEAT_LIMIT
      else
        record[:exit_code] = exit_code
        record[:count] = 1
      end
      @mutation_since_last_bash = false
      nil
    end

    def detect_signature_repeat(sig)
      occurrences = @signature_window.count { |entry| entry[:signature] == sig }
      return nil if occurrences < SIGNATURE_REPEAT_LIMIT
      return nil if @file_mutated_during_window # progress happened, not a stall

      stall(:loop_signature, sig, occurrences)
    end

    def push_signature(sig)
      @signature_window << { signature: sig }
      return unless @signature_window.length > WINDOW_SIZE

      @signature_window.shift
      @file_mutated_during_window = false # reset window progress flag when oldest evicted
    end

    def signature_for(name, input)
      case name
      when 'Edit', 'NotebookEdit'
        "#{name}:#{input['file_path']}:#{short_hash(input['old_string'])}"
      when 'Write'
        "#{name}:#{input['file_path']}:#{short_hash(input['content'])}"
      when 'Read'
        "#{name}:#{input['file_path']}:#{input['offset']}:#{input['limit']}"
      when 'Bash'
        "Bash:#{short_hash(input['command'])}"
      else
        "#{name}:#{short_hash(input.to_json)}"
      end
    end

    def parse_bash_exit_code(item)
      content = item['content']
      text = content.is_a?(Array) ? content.map { |c| c['text'] }.join : content.to_s
      match = text.match(/exit code:?\s*(\d+)/i)
      match && match[1].to_i
    end

    def short_hash(str)
      Digest::SHA1.hexdigest(str.to_s)[0..7]
    end

    def stall(reason, signature, count, detail = nil)
      Stall.new(reason: reason, signature: signature, count: count, detail: detail)
    end
  end
end
