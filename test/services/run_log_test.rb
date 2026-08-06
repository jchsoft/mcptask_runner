# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'json'

# RunLog writes one JSON per execution attempt to log/runs/, refreshed live by the heartbeat
# and finalized with the termination reason — so a hung run leaves its state on disk.
class RunLogTest < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @tmp = Dir.mktmpdir
    Dir.chdir(@tmp)
  end

  def teardown
    Dir.chdir(@orig_dir)
    FileUtils.remove_entry(@tmp)
  end

  def build(now: Time.new(2026, 6, 5, 8, 1, Rational(123, 1000)))
    McptaskRunner::RunLog.new(log_tag: "TodayAutoSquash", session_id: "abcdef12-3456-7890-abcd-ef1234567890", now: now)
  end

  def read(path)
    JSON.parse(File.read(path), symbolize_names: true)
  end

  def test_path_includes_timestamp_tag_and_session_prefix
    assert_equal File.join('log', 'runs', 'run_20260605_080100.123_TodayAutoSquash_abcdef12.json'), build.path
  end

  def test_path_is_unique_for_attempts_in_the_same_second
    now = Time.new(2026, 6, 5, 8, 1, Rational(1, 1000))
    first = McptaskRunner::RunLog.new(log_tag: "TodayAutoSquash", session_id: "abcdef12", now: now)
    second = McptaskRunner::RunLog.new(log_tag: "TodayAutoSquash", session_id: "abcdef12", now: now + 0.5)

    refute_equal first.path, second.path
  end

  def test_start_creates_runs_dir_and_writes_meta
    log = build
    log.start(session_id: "abcdef12", task_id: 10514, task_name: "Fix iPad", model: "minimax-m3:cloud", executor: "TodayAutoSquash")

    assert Dir.exist?(File.join('log', 'runs')), 'log/runs should be created'
    assert File.exist?(log.path)
    rec = read(log.path)
    assert_equal 10514, rec[:task_id]
    assert_equal "minimax-m3:cloud", rec[:model]
    assert rec[:started_at], 'started_at stamped'
  end

  def test_refresh_overwrites_live_state_fields
    log = build
    log.start(session_id: "abcdef12")
    log.refresh(
      snapshot: { status: "processing", active_actions: [{ name: "mcp__mcptask-online__LogWorkProgressTool", elapsed_s: 1062 }], thinking: nil, message: nil },
      timing: { stream_events: 47, inactive_s: 0, stream_quiet_s: 700 }
    )

    rec = read(log.path)
    assert_equal "processing", rec[:status]
    assert_equal 47, rec[:stream_events]
    assert_equal 700, rec[:stream_quiet_s]
    assert_equal "mcp__mcptask-online__LogWorkProgressTool", rec[:active_actions].first[:name]
    assert_equal 1062, rec[:active_actions].first[:elapsed_s]
  end

  def test_finalize_records_termination_and_elapsed
    log = build
    log.start(session_id: "abcdef12")
    log.finalize(
      termination: "inactivity_kill",
      snapshot: { status: "error", error_message: "Absolute stream-silence timeout — killing subprocess", active_actions: [] },
      stream_events: 76,
      elapsed_s: 6150.9
    )

    rec = read(log.path)
    assert_equal "inactivity_kill", rec[:termination]
    assert_equal "error", rec[:final_status]
    assert_equal 6150.9, rec[:elapsed_s]
    assert_match(/stream-silence/, rec[:error_message])
    assert rec[:finished_at]
  end

  def test_record_result_merges_compacted_result
    log = build
    log.start(session_id: "abcdef12")
    log.record_result("status" => "success", "pr_number" => 1251, "branch_name" => "fix/x", "extra" => "ignored")

    rec = read(log.path)
    assert_equal "success", rec[:result][:status]
    assert_equal 1251, rec[:result][:pr_number]
    refute rec[:result].key?(:extra), 'only known result keys are kept'
  end

  def test_record_result_drops_nil_values
    log = build
    log.start(session_id: "abcdef12")
    log.record_result("status" => "no_more_tasks")

    rec = read(log.path)
    assert_equal({ status: "no_more_tasks" }, rec[:result])
  end

  def test_write_failure_is_swallowed
    log = build
    McptaskRunner::Logger.stub(:warn, nil) do
      File.stub(:write, ->(*) { raise IOError, "disk full" }) do
        log.start(session_id: "abcdef12") # must not raise
      end
    end
    refute File.exist?(log.path), 'nothing written when write raises'
  end

  def test_enabled_by_default_and_opt_out
    assert McptaskRunner::RunLog.enabled?
    ENV['MCPTASK_RUN_LOG'] = '0'
    refute McptaskRunner::RunLog.enabled?
  ensure
    ENV.delete('MCPTASK_RUN_LOG')
  end
end
