# frozen_string_literal: true

require 'digest'
require 'time'
require 'fileutils'
require 'mcptask_runner/services/concerns/mcptask_piece_rest'

module McptaskRunner
  # Automatic runner self-failure reporter (type-2).
  #
  # When the runner itself ends a run with a HARD failure (not a success and not a
  # meaningful/expected termination like an urgent-bug pin or a graceful quota bail),
  # this files a bug piece into the fixed "Errors" Epic (#10445, account jchsoft,
  # project #69) with the RunLog JSON and raw stream log attached. This is distinct
  # from BugReporter / bug_destination, which handle bugs the child agent finds in the
  # TARGET project.
  #
  # Design constraints (all fail-safe — a reporting failure must NEVER break a run):
  #   * Destination is FIXED (Errors Epic), never bug_destination.
  #   * Only fires when the runner operates under the jchsoft account (env override
  #     for tests). Other accounts' tokens can't write here, so we don't try.
  #   * Fingerprint + throttle so an error storm can't flood the Epic.
  class RunnerErrorReporter
    include Concerns::McptaskPieceRest

    # Built-in — we report the runner's own failures to our own project, so nothing here is
    # host-configurable. The destination is fixed; the only runtime input is which account the
    # runner is operating under (the gate), read from the already-existing MCPTASK_ACCOUNT / CLAUDE.md.
    DESTINATION = { account: 'jchsoft', project_id: 69, epic_id: 10_445 }.freeze
    # throttle_hours: dedup window; stream_tail_bytes caps the raw stream attachment so a huge
    # log doesn't balloon the upload; hard_statuses are the only terminal outcomes worth reporting.
    CONFIG = { throttle_hours: 6, stream_tail_bytes: 512_000, hard_statuses: %w[error crash].freeze }.freeze
    STATE_FILE = File.join(RunLog::RUNS_DIR, '.error_report_state.json').freeze

    # Fail-safe entry point. Swallows everything — reporting must never abort a run.
    def self.maybe_report(status:, termination:, error_message:, context: {}, run_log_path: nil)
      new(status: status, termination: termination, error_message: error_message,
          context: context, run_log_path: run_log_path).maybe_report
    rescue StandardError => e
      Logger.warn "[RunnerErrorReporter] suppressed: #{e.class}: #{e.message}"
      nil
    end

    def initialize(status:, termination:, error_message:, context: {}, run_log_path: nil)
      @status = status.to_s
      @termination = termination.to_s
      @error_message = error_message.to_s
      @context = context
      @run_log_path = run_log_path
    end

    def maybe_report
      return :skipped_disabled unless enabled?
      return :skipped_not_hard unless hard_failure?
      return :throttled unless claim_fingerprint

      piece_id = post_piece(build_attrs)
      attach_artifacts(piece_id)
      Logger.info_stdout "[RunnerErrorReporter] Reported runner failure (#{@termination}) → Errors Epic ##{DESTINATION[:epic_id]} piece ##{piece_id}"
      piece_id
    end

    private

    def enabled?
      return false if real_http_disabled?
      return false unless under_jchsoft?

      !token.to_s.empty? && !base_url.to_s.empty?
    end

    def hard_failure?
      CONFIG[:hard_statuses].include?(@status)
    end

    # Gate: only report when the runner is operating under the jchsoft account (its
    # token can write to the Errors Epic). Env MCPTASK_ACCOUNT wins; else CLAUDE.md.
    def under_jchsoft?
      runner_account_code == DESTINATION[:account]
    end

    def runner_account_code
      env = ENV['MCPTASK_ACCOUNT'].to_s
      return env unless env.empty?

      claude_md_account_code || DESTINATION[:account]
    end

    def claude_md_account_code
      return nil unless File.exist?('CLAUDE.md')

      File.read('CLAUDE.md')[/account_code:\s*`?([\w-]+)`?/, 1]
    end

    # Destination overrides — fixed Errors Epic, independent of host MCPTASK_ACCOUNT/PROJECT_ID.
    def account_code
      DESTINATION[:account]
    end

    def project_id
      DESTINATION[:project_id]
    end

    def build_attrs
      {
        name: piece_name,
        description: piece_description,
        piece_type: 'Task',
        task_type_code: 'bug',
        priority_code: 'high',
        project_id: project_id,
        parent_id: DESTINATION[:epic_id]
      }
    end

    def piece_name
      task = @context[:task_id] ? " (task ##{@context[:task_id]})" : ''
      "Runner error: #{@termination} — #{@context[:project_name] || 'unknown'}#{task}"[0, 200]
    end

    def piece_description
      <<~DESC
        Automatic runner self-failure report.

        Termination: #{@termination}
        Status: #{@status}
        Reason: #{@context[:reason] || '—'}
        Host project: #{@context[:project_name] || '—'}
        Task: ##{@context[:task_id] || '—'} #{@context[:task_name]}
        Model: #{@context[:model] || '—'}
        Mode: #{@context[:mode] || '—'}
        Machine: #{@context[:machine_id] || '—'}
        Session: #{@context[:session_id] || '—'}
        Elapsed: #{@context[:elapsed_s] || '—'}s

        Error message:
        #{@error_message.empty? ? '(none)' : @error_message}
      DESC
    end

    # --- attachments ---------------------------------------------------------

    def attach_artifacts(piece_id)
      attach_run_log_json(piece_id)
      attach_stream_log(piece_id)
      attach_env_configs(piece_id)
    rescue Concerns::McptaskPieceRest::Error => e
      # Piece already created; a failed attachment shouldn't lose the report.
      Logger.warn "[RunnerErrorReporter] attachment failed: #{e.message}"
    end

    def attach_run_log_json(piece_id)
      path = @run_log_path || Dir.glob(File.join(RunLog::RUNS_DIR, 'run_*.json')).max_by { |f| File.mtime(f) }
      return unless path && File.exist?(path)

      attach_content(piece_id, File.basename(path), File.read(path))
    end

    def attach_stream_log(piece_id)
      path = McptaskRunner::Logger.latest_run_log
      return unless path && File.exist?(path)

      attach_content(piece_id, File.basename(path), read_tail(path, CONFIG[:stream_tail_bytes]))
    end

    def attach_env_configs(piece_id)
      Concerns::McptaskPieceRest::ENV_CONFIGS.each do |relative_path|
        full_path = File.join(Dir.pwd, relative_path)
        next unless File.exist?(full_path)

        attach_content(piece_id, File.basename(relative_path), redact_tokens(File.read(full_path)))
      end
    end

    def read_tail(path, max_bytes)
      size = File.size(path)
      return File.read(path) if size <= max_bytes

      File.open(path) do |f|
        f.seek(size - max_bytes)
        "…[truncated #{size - max_bytes} bytes]…\n#{f.read}"
      end
    end

    # --- fingerprint + throttle ---------------------------------------------

    # Returns true when this failure is newly claimed (report it), false when an
    # identical failure was already reported inside the throttle window (skip it).
    def claim_fingerprint
      now = Time.now
      state = prune(load_state, now - throttle_window_seconds)
      return false if state.key?(fingerprint)

      state[fingerprint] = now.utc.iso8601
      write_state(state)
      true
    end

    def fingerprint
      @fingerprint ||= Digest::SHA256.hexdigest(
        [@termination, normalize(@error_message), @context[:task_id], @context[:project_name]].join('|')
      )[0, 16]
    end

    # Collapse run-specific noise (paths, hashes, numbers) so the same failure fingerprints
    # identically across runs.
    def normalize(message)
      message.to_s.downcase
             .gsub(%r{/[^\s'"]+}, '/PATH')
             .gsub(/\b[0-9a-f]{8,}\b/, 'HEX')
             .gsub(/\d+(\.\d+)?/, 'N')
             .gsub(/\s+/, ' ').strip[0, 200]
    end

    def throttle_window_seconds
      CONFIG[:throttle_hours] * 3600
    end

    def prune(state, cutoff)
      state.reject do |_fp, iso|
        Time.parse(iso) < cutoff
      rescue ArgumentError, TypeError
        true
      end
    end

    def load_state
      return {} unless File.exist?(STATE_FILE)

      JSON.parse(File.read(STATE_FILE))
    rescue StandardError
      {}
    end

    def write_state(state)
      FileUtils.mkdir_p(RunLog::RUNS_DIR)
      File.write(STATE_FILE, JSON.pretty_generate(state))
    rescue StandardError => e
      Logger.warn "[RunnerErrorReporter] state write failed: #{e.message}"
    end
  end
end
