# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module McptaskRunner
  # Structured per-execution-attempt record written to log/runs/*.json.
  #
  # One JSON file per Claude execution attempt. The heartbeat tick calls #refresh every cycle,
  # so a hung run leaves its current in-flight state (active tool + how long it has been
  # running, status, stream counters) on disk; #finalize stamps the termination reason and
  # parsed result when the attempt ends. This turns a "why is the runner stuck for 90 minutes"
  # investigation — which previously meant grepping a 268k-line raw stream log — into a single
  # file read.
  #
  # Every write is best-effort and rescue-guarded: a logging failure must NEVER break a run.
  class RunLog
    RUNS_DIR = File.join('log', 'runs').freeze

    # Opt-out only. Disabled with MCPTASK_RUN_LOG=0 (e.g. for tests that should not touch disk).
    def self.enabled?
      ENV['MCPTASK_RUN_LOG'] != '0'
    end

    attr_reader :path

    def initialize(log_tag:, session_id:, now: Time.now)
      @log_tag = log_tag
      session8 = session_id.to_s.delete('-')[0, 8]
      @path = File.join(RUNS_DIR, "run_#{now.strftime('%Y%m%d_%H%M%S')}_#{log_tag}_#{session8}.json")
      @record = {}
    end

    # meta: identity + attempt context (session_id, project_name, machine_id, task_id/name,
    # model, mode, retry_count, marker_retry, pid). Written immediately so even an instant
    # crash leaves a record.
    def start(meta)
      @record = meta.transform_keys(&:to_sym)
      @record[:started_at] = iso_now
      write
    end

    # Called from the heartbeat each cycle — overwrites the live state fields.
    def refresh(snapshot:, timing:)
      @record.merge!(
        status: snapshot[:status],
        active_actions: snapshot[:active_actions],
        thinking: snapshot[:thinking],
        message: snapshot[:message],
        stream_events: timing[:stream_events],
        inactive_s: timing[:inactive_s],
        stream_quiet_s: timing[:stream_quiet_s],
        updated_at: iso_now
      )
      write
    end

    def finalize(termination:, snapshot:, stream_events:, elapsed_s:)
      @record.merge!(
        termination: termination,
        final_status: snapshot[:status],
        error_message: snapshot[:error_message],
        active_actions: snapshot[:active_actions],
        stream_events: stream_events,
        elapsed_s: elapsed_s,
        finished_at: iso_now
      )
      write
    end

    # Merge the parsed TASKRUNNER_RESULT once the stream has been parsed.
    def record_result(result)
      @record[:result] = {
        status: result['status'],
        pr_number: result['pr_number'],
        branch_name: result['branch_name']
      }.compact
      write
    end

    private

    def iso_now
      Time.now.utc.iso8601(3)
    end

    def write
      FileUtils.mkdir_p(RUNS_DIR)
      File.write(@path, JSON.pretty_generate(@record))
    rescue StandardError => e
      Logger.warn "[#{@log_tag}] RunLog write failed: #{e.message}"
    end
  end
end
