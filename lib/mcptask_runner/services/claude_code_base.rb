# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'json'
require 'securerandom'
require 'shellwords'
require 'timeout'
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

  # Raised when daily quota crosses per_day while a Claude run is in progress.
  # Terminal: heartbeat already SIGTERMed the subprocess; caller must NOT retry.
  class QuotaExceededMidTaskError < StandardError; end

  # Raised when StallDetector flags the session as spinning (repeated failed tool calls,
  # edit-failure streak, no progress in a window). Terminal: the task stays in_progress
  # so the next triage promotes to Opus via TriageExecution#upgrade_model_for_resume.
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
  # - model_name() -> returns the model to use (e.g., 'sonnet', 'haiku', 'opus')
  class ClaudeCodeBase
    include Concerns::ProcessManagement
    include Concerns::RetryHandling
    include Concerns::StreamProcessing
    include Concerns::ResultParsing
    include Concerns::InstructionBuilding
    include Concerns::HeartbeatMonitoring

    # Pin to standard 200K-context model IDs (no [1m] suffix) so context overflows fail fast
    # at ~200K instead of growing to 1M across --continue retry chains.
    # Update IDs when newer models are released.
    MODEL_IDS = {
      'opus' => 'claude-opus-4-7',
      'sonnet' => 'claude-sonnet-4-6',
      'haiku' => 'claude-haiku-4-5-20251001'
    }.freeze

    # Per-attempt streaming/termination flags. Collected into one struct so the host
    # class stays under Reek's TooManyInstanceVariables threshold.
    ExecutionState = Struct.new(
      :stopping, :result_received, :inactivity_timeout, :quota_exceeded,
      :api_overload, :context_overflow, :stalled, :child_pid, :stream_line_count,
      keyword_init: true
    ) do
      def self.fresh
        new(stopping: false, result_received: false, inactivity_timeout: false,
            quota_exceeded: false, api_overload: false, context_overflow: false,
            stalled: nil, child_pid: nil, stream_line_count: 0)
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
      @state = ExecutionState.fresh
      @log_tag = self.class.name.split('::').last
      @snapshot_builder = snapshot_builder || SnapshotBuilder.new(
        session_id: SecureRandom.uuid,
        machine_id: ENV.fetch("HOSTNAME") { `hostname`.strip }
      )
      @stall_detector = StallDetector.new(@log_tag)
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
      claude_path = resolve_claude_path
      instructions = @retry_state.marker_retry_mode ? build_marker_retry_instructions : build_instructions
      command = build_command(claude_path, instructions, continue_session: @retry_state.count.positive? || @retry_state.marker_retry_mode)

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

      # Claude emitted TASKRUNNER_RESULT — trust its terminal output even if context-overflow
      # or 529 patterns appeared earlier in the stream. Those may be sub-agent or transient
      # errors Claude already recovered from; overriding here would discard a real success.
      return result if @state.result_received && !marker_parse_failed?(result)

      # Detect context overflow BEFORE other errors - session is dead, --continue cannot recover
      raise ContextOverflowError if context_overflow_detected?

      # Detect API overload - Claude crashed due to 529 errors, not a real failure
      raise ApiOverloadError if api_overload_detected?

      # If marker not found and Claude completed successfully, retry with marker-only instruction
      raise MissingMarkerError if marker_parse_failed?(result)

      result
    rescue Timeout::Error
      raise ContextOverflowError if @state.context_overflow

      handle_recoverable_error('Timeout', start_time)
    rescue StreamClosedError => e
      raise ContextOverflowError if @state.context_overflow
      raise ApiOverloadError if @state.api_overload

      handle_recoverable_error("Stream closed: #{e.message}", start_time)
    rescue MissingMarkerError
      handle_marker_retry(start_time)
    rescue ApiOverloadError
      handle_api_overload(start_time)
    rescue ContextOverflowError
      handle_context_overflow(start_time)
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

    def build_command(claude_path, instructions, continue_session: false)
      cmd = [claude_path]
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
    end

    def quota_exceeded_now?(execution_start, now)
      watch = @quota_watch or return false

      per_day = watch[:per_day_hours].to_f
      return false unless per_day.positive?

      watch[:already_worked_hours].to_f + ((now - execution_start) / 3600.0) >= per_day
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
      stdout_content = ''.dup
      stderr_content = ''.dup
      reset_streaming_state
      @snapshot_builder.set_model(effective_model_name)
      EventStream.emit_snapshot(@snapshot_builder.to_h, force: true)
      execution_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        @state.child_pid = wait_thr.pid
        stdin.close

        stdout_thread    = start_stdout_thread(stdout, stdout_content)
        stderr_thread    = start_stderr_thread(stderr, stderr_content)
        heartbeat_thread = Thread.new { heartbeat_loop(stderr_content, execution_start) }

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
      check_for_mcp_server_status(line)
      check_for_context_overflow(line)
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
      return unless @snapshot_builder.status == "processing"

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
