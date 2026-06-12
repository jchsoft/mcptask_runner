# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'json'
require 'securerandom'
require 'shellwords'
require 'timeout'
require 'yaml'
require_relative 'output_formatter'
require_relative 'stall_detector'
require_relative 'concerns/process_management'
require_relative 'concerns/retry_handling'
require_relative 'concerns/stream_processing'
require_relative 'concerns/result_parsing'
require_relative 'concerns/instruction_building'
require_relative 'concerns/heartbeat_monitoring'

module McptaskRunner
  # Raised when IO stream unexpectedly closes during Claude execution
  class StreamClosedError < StandardError; end

  # Raised when TASKRUNNER_RESULT marker is not found in output
  class MissingMarkerError < StandardError; end

  # Raised when Claude exits due to API overload (529 errors)
  class ApiOverloadError < StandardError; end

  # Raised when Claude session context exceeds 1M token limit ("Prompt is too long").
  # Terminal: session is unrecoverable, --continue on same session would re-trigger the error.
  class ContextOverflowError < StandardError; end

  # Raised when an MCP tool returns "exists but is not enabled in this context",
  # i.e. the MCP server connection is missing at Claude startup (config gone / token bad).
  # Terminal: server can't be reattached mid-session, marker retries would just balloon context.
  class ToolNotEnabledError < StandardError; end

  # Raised when daily quota crosses per_day while a Claude run is in progress.
  # Terminal: heartbeat already SIGTERMed the subprocess; caller must NOT retry.
  class QuotaExceededMidTaskError < StandardError; end

  # Raised when StallDetector flags the session as spinning (repeated failed tool calls,
  # edit-failure streak, no progress in a window). Terminal: the task stays in_progress
  # so the next triage promotes to genius via TriageExecution#upgrade_model_for_resume.
  class StalledError < StandardError
    attr_reader :stall

    def initialize(stall)
      super("Stalled: reason=#{stall.reason} signature=#{stall.signature} count=#{stall.count}")
      @stall = stall
    end
  end

  # Base class for Claude Code executors
  # Handles common execution, streaming, and JSON parsing logic
  # Subclasses must implement:
  # - build_instructions() -> returns instruction string
  # - model_name() -> returns the spice level (e.g., 'smart', 'primitive', 'genius')
  class ClaudeCodeBase
    include Concerns::ProcessManagement
    include Concerns::RetryHandling
    include Concerns::StreamProcessing
    include Concerns::ResultParsing
    include Concerns::InstructionBuilding
    include Concerns::HeartbeatMonitoring

    # Spice-level => Claude model ID mapping.
    #
    # The host project (where the runner runs) may provide config/models.yml to PIN
    # specific versioned IDs (e.g. standard 200K-context variants, no [1m] suffix) so
    # context overflows fail fast at ~200K instead of growing to 1M across --continue
    # retry chains. When that file is absent we fall back to generic, unversioned CLI
    # aliases — Claude resolves them to its current default models.
    GENERIC_MODEL_IDS = {
      'genius' => 'opus',
      'smart' => 'sonnet',
      'primitive' => 'haiku'
    }.freeze

    MODELS_FILE = File.join(Dir.pwd, 'config', 'models.yml').freeze
    MODEL_IDS_FROM_FILE = File.exist?(MODELS_FILE)
    MODEL_IDS = (MODEL_IDS_FROM_FILE ? YAML.load_file(MODELS_FILE) : GENERIC_MODEL_IDS).freeze

    # Tier-alias overrides for forked skills / subagents. The --model flag pins only the MAIN
    # process; a fork that declares `model: haiku` (or sonnet/opus) in its frontmatter resolves
    # that alias through these env vars, falling back to the built-in Anthropic IDs
    # (e.g. claude-haiku-4-5-...) when they are unset. On a host whose config/models.yml pins a
    # non-Anthropic backend (ollama/minimax), those built-in IDs do not exist and the fork dies
    # with "model ... may not exist" — so we export the pinned IDs here too. Only when models.yml
    # is present: the generic fallback values are aliases ('haiku'), not the full model names these
    # vars require, and unset is already correct on Anthropic hosts.
    FORK_MODEL_ENV = (MODEL_IDS_FROM_FILE ? {
      'ANTHROPIC_DEFAULT_OPUS_MODEL' => MODEL_IDS['genius'],
      'ANTHROPIC_DEFAULT_SONNET_MODEL' => MODEL_IDS['smart'],
      'ANTHROPIC_DEFAULT_HAIKU_MODEL' => MODEL_IDS['primitive']
    }.compact : {}).freeze

    # Optional per-host-project launcher override. When config/launcher.yml exists in the
    # project where the runner runs, its `command:` array REPLACES the default `[claude_path]`
    # prefix — e.g. [ollama, launch, claude] to route through an alternate backend for testing.
    # The runner still appends its own flags (-p, --model, --output-format=stream-json, …) and
    # still derives --model from config/models.yml, so the stream-json contract stays intact.
    LAUNCHER_FILE = File.join(Dir.pwd, 'config', 'launcher.yml').freeze
    CLAUDE_COMMAND_PREFIX = (File.exist?(LAUNCHER_FILE) ? YAML.load_file(LAUNCHER_FILE) : {})['command'].freeze

    # One-line description of where model IDs came from, for the boot banner.
    def self.model_source_description
      pairs = MODEL_IDS.map { |level, id| "#{level}=#{id}" }.join(', ')
      source = MODEL_IDS_FROM_FILE ? "config/models.yml (pinned): #{pairs}" : "generic aliases (no config/models.yml): #{pairs}"
      fork_note = FORK_MODEL_ENV.empty? ? '' : " | fork aliases -> #{FORK_MODEL_ENV.values.uniq.join(', ')}"
      "Models: #{source}#{fork_note}"
    end

    # One-line description of the launch command prefix, for the boot banner.
    def self.launcher_source_description
      return 'Launcher: default (claude binary autodetect / CLAUDE_PATH)' unless CLAUDE_COMMAND_PREFIX

      "Launcher: config/launcher.yml override -> #{CLAUDE_COMMAND_PREFIX.join(' ')}"
    end

    # Per-attempt streaming/termination flags. Collected into one struct so the host
    # class stays under Reek's TooManyInstanceVariables threshold.
    ExecutionState = Struct.new(
      :stopping, :result_received, :inactivity_timeout, :quota_exceeded,
      :api_overload, :context_overflow, :tool_not_enabled, :stalled, :child_pid, :stream_line_count,
      keyword_init: true
    ) do
      def self.fresh
        new(stopping: false, result_received: false, inactivity_timeout: false,
            quota_exceeded: false, api_overload: false, context_overflow: false,
            tool_not_enabled: false, stalled: nil, child_pid: nil, stream_line_count: 0)
      end
    end

    # Set by WorkLoop before #run when mid-task quota guarding is desired.
    # Hash with :per_day_hours and :already_worked_hours (both Float).
    # nil = no guard (used by Triage / Review / Dry executors).
    def quota_watch=(val)
      @quota_watch = val
      @snapshot_builder.set_quota(per_day_hours: val[:per_day_hours], already_worked_hours: val[:already_worked_hours]) if val
    end

    def initialize(verbose: false, model_override: nil, resuming: false, snapshot_builder: nil, **)
      @verbose = verbose
      @model_override = model_override
      @resuming = resuming
      @retry_state = Concerns::RetryHandling::RetryState.initial
      @quota_watch = nil
      @last_quota_poll_at = 0.0
      @quota_rest_failures = 0
      @state = ExecutionState.fresh
      @log_tag = self.class.name.split('::').last
      @snapshot_builder = snapshot_builder || SnapshotBuilder.new(
        session_id: SecureRandom.uuid,
        machine_id: ENV.fetch("HOSTNAME") { `hostname`.strip },
        project_name: ClaudeMd.project_name
      )
      @stall_detector = StallDetector.new(@log_tag)
      @run_log = nil
      OutputFormatter.verbose_mode = verbose
    end

    def run
      Logger.info_stdout "[#{@log_tag}] Starting execution..."
      Logger.info_stdout "[#{@log_tag}] Output mode: #{@verbose ? 'VERBOSE' : 'NORMAL'}"
      start_time = Time.now
      @accumulated_output = ''.dup
      @text_content = ''.dup

      run_with_retry(start_time)
    end

    private

    def attempt_execution(start_time)
      # A fresh restart (post context-overflow) consumes its flag here: no --continue, and the
      # normal workflow instructions (a fresh session can't continue a marker-only prompt;
      # continuation is re-detected from task progress + git branch). Reset per-attempt so a
      # later non-overflow failure of the healthy fresh session retries normally with --continue.
      fresh = @retry_state.fresh_restart
      @retry_state.fresh_restart = false
      instructions = @retry_state.marker_retry_mode && !fresh ? build_marker_retry_instructions : build_instructions
      command = build_command(base_command, instructions,
                              continue_session: (@retry_state.count.positive? || @retry_state.marker_retry_mode) && !fresh)

      Logger.debug "[#{@log_tag}] Executing Claude with instructions (length: #{instructions.length} chars)"
      Logger.info_stdout "[#{@log_tag}] Starting real-time stream of Claude output:"
      Logger.info_stdout "[#{@log_tag}] Retry attempt: #{@retry_state.count + 1}/#{MAX_RETRY_ATTEMPTS}" if @retry_state.count.positive?
      Logger.info_stdout "[#{@log_tag}] Marker retry mode: ON" if @retry_state.marker_retry_mode
      Logger.info_stdout '-' * 80

      stdout_content = execute_with_streaming(command)
      @accumulated_output << stdout_content

      Logger.info_stdout '-' * 80
      Logger.info_stdout "[#{@log_tag}] Claude execution completed, parsing results..."

      elapsed_hours = ((Time.now - start_time) / 3600.0).round(2)
      Logger.info_stdout "[#{@log_tag}] Elapsed time: #{elapsed_hours} hours"

      result = parse_result(@accumulated_output, elapsed_hours)
      @run_log&.record_result(result)

      # Claude emitted TASKRUNNER_RESULT — trust its terminal output even if context-overflow
      # or 529 patterns appeared earlier in the stream. Those may be sub-agent or transient
      # errors Claude already recovered from; overriding here would discard a real success.
      return result if @state.result_received && !marker_parse_failed?(result)

      # Detect context overflow BEFORE other errors - session is dead, --continue cannot recover
      raise ContextOverflowError if context_overflow_detected?

      # Detect MCP "tool not enabled" — server missing at startup, marker retry would just
      # balloon context with the same failure.
      raise ToolNotEnabledError if tool_not_enabled_detected?

      # Detect API overload - Claude crashed due to 529 errors, not a real failure
      raise ApiOverloadError if api_overload_detected?

      # If marker not found and Claude completed successfully, retry with marker-only instruction
      raise MissingMarkerError if marker_parse_failed?(result)

      result
    rescue Timeout::Error
      raise ContextOverflowError if @state.context_overflow
      raise ToolNotEnabledError if @state.tool_not_enabled

      handle_recoverable_error('Timeout', start_time)
    rescue StreamClosedError => e
      raise ContextOverflowError if @state.context_overflow
      raise ToolNotEnabledError if @state.tool_not_enabled
      raise ApiOverloadError if @state.api_overload

      handle_recoverable_error("Stream closed: #{e.message}", start_time)
    rescue MissingMarkerError
      handle_marker_retry(start_time)
    rescue ApiOverloadError
      handle_api_overload(start_time)
    rescue ContextOverflowError
      handle_context_overflow(start_time)
    rescue ToolNotEnabledError
      handle_tool_not_enabled(start_time)
    rescue StalledError => e
      handle_stalled(e.stall, start_time)
    end

    def resolve_claude_path
      Logger.debug "[#{@log_tag}] Resolving Claude executable path..."
      claude_path = ENV['CLAUDE_PATH'] || find_claude_executable
      raise 'Claude executable not found. Set CLAUDE_PATH environment variable.' unless claude_path

      Logger.info_stdout "[#{@log_tag}] Found Claude at: #{claude_path}"
      claude_path
    end

    # Base launch command: per-project config/launcher.yml override, else the autodetected
    # claude binary. Returns a fresh array each call so build_command can mutate it safely.
    def base_command
      CLAUDE_COMMAND_PREFIX&.dup || [resolve_claude_path]
    end

    def build_command(base, instructions, continue_session: false)
      cmd = base
      cmd << '--continue' if continue_session
      cmd.concat(['-p', instructions, '--model', effective_model_name, '--output-format=stream-json', '--verbose'])
      cmd.concat(['--max-turns', max_turns.to_s]) if max_turns
      cmd << '--permission-mode=bypassPermissions' if accept_edits?
      Logger.debug "command: #{cmd.map { |arg| Shellwords.escape(arg) }.join(' ')}"
      cmd
    end

    def accept_edits?
      true # Override in subclass if needed
    end

    # Per-invocation turn cap. Subclasses override; nil = no cap.
    def max_turns
      nil
    end

    def effective_model_name
      raw = @model_override || model_name
      MODEL_IDS.fetch(raw, raw)
    end

    def reset_streaming_state
      @state = ExecutionState.fresh
      @stall_detector = StallDetector.new(@log_tag)
      @last_quota_poll_at = 0.0
      @quota_rest_failures = 0
      @run_log = nil
    end

    # Open a fresh per-attempt run record once the child pid is known. Best-effort: a logging
    # failure must never abort the run, so swallow and continue.
    def start_run_log
      return unless RunLog.enabled?

      snap = @snapshot_builder.to_h
      @run_log = RunLog.new(log_tag: @log_tag, session_id: snap[:session_id])
      @run_log.start(
        session_id: snap[:session_id], machine_id: snap[:machine_id], project_name: snap[:project_name],
        task_id: snap[:task_id], task_name: snap[:task_name], model: snap[:model], executor: @log_tag,
        pid: @state.child_pid, retry_count: @retry_state.count, marker_retry: @retry_state.marker_retry_mode
      )
    rescue StandardError => e
      Logger.warn "[#{@log_tag}] RunLog start failed: #{e.message}"
    end

    # Stamp the terminal record. Called before clear_active_actions so a hung tool is captured.
    def finalize_run_log(elapsed)
      @run_log&.finalize(
        termination: derive_termination_reason,
        snapshot: @snapshot_builder.to_h,
        stream_events: @state.stream_line_count,
        elapsed_s: elapsed
      )
    rescue StandardError => e
      Logger.warn "[#{@log_tag}] RunLog finalize failed: #{e.message}"
    end

    # Why the attempt ended, derived from terminal @state flags. error_message in the snapshot
    # carries the finer detail (e.g. absolute-silence vs ordinary inactivity).
    def derive_termination_reason
      return 'result' if @state.result_received
      return 'inactivity_kill' if @state.inactivity_timeout
      return 'quota' if @state.quota_exceeded
      return "stalled:#{@state.stalled.reason}" if @state.stalled
      return 'context_overflow' if @state.context_overflow
      return 'tool_not_enabled' if @state.tool_not_enabled
      return 'api_overload' if @state.api_overload

      'stream_ended'
    end

    def raise_streaming_errors_if_any(stream_error)
      raise StalledError, @state.stalled if @state.stalled
      raise StreamClosedError, stream_error if stream_error && !@state.stopping
      raise Timeout::Error, "Claude inactive for #{INACTIVITY_TIMEOUT}s" if @state.inactivity_timeout
      raise QuotaExceededMidTaskError, 'daily quota exceeded during run' if @state.quota_exceeded
    end

    def log_exit_status(exit_status, stderr_content)
      return unless exit_status

      Logger.debug "[#{@log_tag}] Process exit status: #{exit_status.exitstatus}"
      return unless exit_status.exitstatus != 0 && !@state.result_received

      Logger.debug "[#{@log_tag}] WARNING: Claude exited with non-zero status!"
      Logger.debug "[#{@log_tag}] stderr: #{stderr_content}" unless stderr_content.empty?
    end

    def execute_with_streaming(command)
      raise "Refusing to spawn real Claude subprocess: #{EventStream::DISABLE_ENV} is set (this test forgot to stub execute_with_streaming)" unless ENV[EventStream::DISABLE_ENV].to_s.empty?

      stdout_content = ''.dup
      stderr_content = ''.dup
      reset_streaming_state
      @snapshot_builder.set_model(effective_model_name)
      EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
      execution_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Open3.popen3(FORK_MODEL_ENV, *command, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        @state.child_pid = wait_thr.pid
        stdin.close
        start_run_log

        stdout_thread    = start_stdout_thread(stdout, stdout_content)
        stderr_thread    = start_stderr_thread(stderr, stderr_content)
        heartbeat_thread = start_supervised_heartbeat(stderr_content, execution_start)

        join_streaming_threads(stdout_thread, stderr_thread, heartbeat_thread, wait_thr, stderr_content)
      end

      finalize_streaming(execution_start)
      stdout_content
    end

    def join_streaming_threads(stdout_thread, stderr_thread, heartbeat_thread, wait_thr, stderr_content)
      # Kill process first if result received, so streams close and threads unblock
      kill_process(@state.child_pid) if @state.result_received

      stdout_thread.join
      stderr_thread.join(30)
      stream_error = stdout_thread[:stream_error] || stderr_thread[:stream_error]
      raise_streaming_errors_if_any(stream_error)
      log_exit_status(wait_for_process(wait_thr), stderr_content)
    ensure
      heartbeat_thread&.kill
      kill_process(@state.child_pid) unless @state.result_received
    end

    def start_stdout_thread(stdout, stdout_content)
      Thread.new do
        stream_lines(stdout) { |line| process_stdout_line(line, stdout_content) }
      rescue IOError, Errno::EBADF => e
        handle_stream_error(e, 'stdout') { |err| Thread.current[:stream_error] = err }
      rescue StandardError => e
        Logger.error "[#{@log_tag}] stdout thread crashed: #{e.class}: #{e.message}"
        Thread.current[:stream_error] = "stdout thread crashed: #{e.message}" unless @state.stopping
      end
    end

    def process_stdout_line(line, stdout_content)
      stdout_content << line.dup
      @state.stream_line_count += 1
      @text_content << extract_text_from_line(line)
      track_tool_event(line)
      track_system_task_event(line)
      check_for_mcp_server_status(line)
      check_for_context_overflow(line)
      check_for_tool_not_enabled(line)
      check_for_api_overload(line)
      check_for_result_message(line)
      if OutputFormatter.should_log_to_stdout?(line)
        formatted = OutputFormatter.format_line(line)
        puts formatted
        Logger.info(formatted)
      else
        Logger.debug("[#{@log_tag}] [streaming] #{line.strip}")
      end
    end

    def start_stderr_thread(stderr, stderr_content)
      Thread.new do
        stream_lines(stderr) do |line|
          Logger.warn "\n[Claude STDERR] #{line}"
          stderr_content << line.dup
          check_for_context_overflow(line)
        end
      rescue IOError, Errno::EBADF => e
        handle_stream_error(e, 'stderr') { |err| Thread.current[:stream_error] = err }
      rescue StandardError => e
        Logger.error "[#{@log_tag}] stderr thread crashed: #{e.class}: #{e.message}"
      end
    end

    def finalize_streaming(execution_start)
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - execution_start).round(1)
      Logger.info_stdout "[#{@log_tag}] Execution finished in #{elapsed}s (#{@state.stream_line_count} stream events)"
      finalize_run_log(elapsed)
      @snapshot_builder.clear_active_actions
      return unless %w[processing pending].include?(@snapshot_builder.status)

      @snapshot_builder.set_status(:processing) if @snapshot_builder.status == "pending"
      @snapshot_builder.set_status(:finished)
      EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
    end

    def build_instructions
      raise NotImplementedError, "#{self.class} must implement build_instructions"
    end

    def model_name
      raise NotImplementedError, "#{self.class} must implement model_name"
    end

    def error_result(message)
      Logger.debug "[#{@log_tag}] [error_result] Creating error result: #{message}"
      { 'status' => 'error', 'message' => message }
    end

    def marker_parse_failed?(result)
      result['status'] == 'error' && result['message'].to_s.include?('TASKRUNNER_RESULT')
    end

    def release_test_lock
      test_lock = File.expand_path('~/.claude/bin/test_lock')
      return unless File.executable?(test_lock)

      system(test_lock, 'release')
    rescue StandardError => e
      Logger.warn "[#{@log_tag}] Failed to release test lock: #{e.message}"
    end

    def find_claude_executable
      Logger.debug "[#{@log_tag}] [find_claude_executable] Searching for Claude executable..."
      paths = %w[~/.claude/local/claude ~/.local/bin/claude /usr/local/bin/claude /opt/homebrew/bin/claude]

      paths.each do |path|
        expanded_path = File.expand_path(path)
        Logger.debug "[#{@log_tag}] [find_claude_executable] Checking: #{expanded_path}"
        if File.executable?(expanded_path)
          Logger.debug "[#{@log_tag}] [find_claude_executable] Found executable Claude at: #{expanded_path}"
          return expanded_path
        else
          Logger.debug "[#{@log_tag}] [find_claude_executable] Not found or not executable: #{expanded_path}"
        end
      end

      Logger.debug "[#{@log_tag}] [find_claude_executable] Trying 'which claude' fallback..."
      which_path = find_claude_via_which
      if which_path
        Logger.debug "[#{@log_tag}] [find_claude_executable] Found executable Claude via 'which': #{which_path}"
        return which_path
      end

      Logger.debug "[#{@log_tag}] [find_claude_executable] ERROR: Claude executable not found in any standard locations"
      nil
    end

    def find_claude_via_which
      output = IO.popen(['which', 'claude'], &:read).strip
      return output if output && !output.empty? && File.executable?(output)

      nil
    rescue StandardError => e
      Logger.debug "[#{@log_tag}] [find_claude_via_which] Error running 'which claude': #{e.message}"
      nil
    end

    def project_relative_id
      return nil unless File.exist?('CLAUDE.md')

      File.read('CLAUDE.md').match(/project_relative_id=(\d+)/)&.then { |m| m[1].to_i }
    end
  end
end
