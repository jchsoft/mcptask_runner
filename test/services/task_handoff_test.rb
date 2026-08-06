# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'json'

# TaskHandoff persists a context-overflow note per task under log/handoffs/, so the NEXT runner
# process that picks the same task up is told it is a repeat attempt instead of re-exploring its
# way into the same wall. See McptaskRunner::TaskHandoff.
class TaskHandoffTest < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @tmp = Dir.mktmpdir
    Dir.chdir(@tmp)
  end

  def teardown
    Dir.chdir(@orig_dir)
    FileUtils.remove_entry(@tmp)
  end

  def builder(task_id: 11_291, task_name: 'Business-value features')
    McptaskRunner::SnapshotBuilder.new(session_id: 'sess-1', machine_id: 'mac-mini', project_name: 'projectoid_ii').tap do |sb|
      sb.set_task(task_id: task_id, task_name: task_name)
      sb.set_model('kimi-k2.7-code:cloud')
    end
  end

  def record(task_id: 11_291, builder: nil, terminal: true, message: 'Context overflow after 0.26h', elapsed_s: 946.9)
    McptaskRunner::TaskHandoff.record_overflow(
      McptaskRunner::TaskHandoff::Overflow.new(task_id: task_id, mode: 'TodayAutoSquash', elapsed_s: elapsed_s,
                                              terminal: terminal, message: message),
      builder || builder(task_id: task_id)
    )
  end

  def read(task_id)
    JSON.parse(File.read(McptaskRunner::TaskHandoff.path_for(task_id)))
  end

  def test_record_overflow_writes_note_under_log_handoffs
    record

    assert_equal File.join('log', 'handoffs', 'task_11291.json'), McptaskRunner::TaskHandoff.path_for(11_291)
    note = read(11_291)
    assert_equal 11_291, note['task_id']
    assert_equal 'Business-value features', note['task_name']
    assert_equal 'TodayAutoSquash', note['mode']
    assert_equal 'kimi-k2.7-code:cloud', note['model']
    assert_equal 946.9, note['elapsed_s']
    assert note['terminal']
    assert_match(/Context overflow/, note['last_error'])
  end

  def test_load_returns_nil_when_no_note
    assert_nil McptaskRunner::TaskHandoff.load(11_291)
  end

  def test_load_returns_nil_without_task_id
    assert_nil McptaskRunner::TaskHandoff.load(nil), 'a task-less executor (triage) must never look one up'
  end

  def test_record_overflow_is_a_noop_without_task_id
    assert_nil record(task_id: nil)
    refute Dir.exist?(File.join('log', 'handoffs')), 'must not create the dir when there is no task to key on'
  end

  # The counter is the whole point: it must survive the process boundary, since each runner cycle
  # starts a brand-new RetryState whose overflow_restart_count is back to 0.
  def test_overflow_count_accumulates_across_records
    assert_equal 1, record.overflow_count
    assert_equal 2, record.overflow_count
    assert_equal 2, McptaskRunner::TaskHandoff.load(11_291).overflow_count
  end

  def test_first_overflow_at_is_preserved_across_records
    first = record.data['first_overflow_at']
    sleep 0.002
    second = record

    assert_equal first, second.data['first_overflow_at'], 'first sighting must not be overwritten'
    refute_equal first, second.data['updated_at'], 'last sighting must move'
  end

  def test_record_captures_recent_actions_and_open_todos
    sb = builder
    sb.tool_started(tool_id: 't1', name: 'Bash', summary: 'bin/ci')
    sb.tool_finished(tool_id: 't1')
    sb.set_todos([{ 'content' => 'Write the diff table', 'status' => 'in_progress' },
                  { 'content' => 'Already done bit', 'status' => 'completed' }])

    note = record(builder: sb).data

    assert_equal ['Bash: bin/ci'], note['recent_actions']
    assert_equal ['Write the diff table'], note['open_todos'], 'completed todos are not unfinished work'
  end

  def test_clear_removes_the_note
    record
    McptaskRunner::TaskHandoff.clear(11_291)

    assert_nil McptaskRunner::TaskHandoff.load(11_291)
  end

  def test_clear_is_safe_when_note_absent
    McptaskRunner::TaskHandoff.clear(11_291) # must not raise
    assert_nil McptaskRunner::TaskHandoff.load(11_291)
  end

  def test_record_prunes_notes_older_than_max_age
    stale = McptaskRunner::TaskHandoff.path_for(999)
    FileUtils.mkdir_p(File.dirname(stale))
    File.write(stale, '{}')
    File.utime(Time.now - (McptaskRunner::TaskHandoff::MAX_AGE_DAYS * 86_400) - 60, Time.now - (McptaskRunner::TaskHandoff::MAX_AGE_DAYS * 86_400) - 60, stale)

    record

    refute File.exist?(stale), 'an abandoned task must not nag runs forever'
    assert File.exist?(McptaskRunner::TaskHandoff.path_for(11_291))
  end

  def test_load_survives_corrupt_note
    path = McptaskRunner::TaskHandoff.path_for(11_291)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'not json {{')

    assert_nil McptaskRunner::TaskHandoff.load(11_291), 'a bad note must degrade to "no note", never raise'
  end

  def test_disabled_by_env_flag
    ENV['MCPTASK_TASK_HANDOFF'] = '0'
    assert_nil record
    refute Dir.exist?(File.join('log', 'handoffs'))
  ensure
    ENV.delete('MCPTASK_TASK_HANDOFF')
  end

  def test_preamble_states_repeat_attempt_and_context_budget
    preamble = record.preamble

    assert_match(/REPEAT ATTEMPT/, preamble)
    assert_match(/Prompt is too long/, preamble)
    assert_match(/CONTEXT BUDGET/, preamble)
    assert_match(/kimi-k2\.7-code:cloud/, preamble)
    assert_match(/do NOT start from scratch|Do NOT re-explore/i, preamble)
  end

  def test_preamble_pluralizes_attempt_count
    assert_match(/a previous session/, record.preamble)
    assert_match(/2 previous sessions/, record.preamble)
  end

  def test_preamble_lists_recent_actions_and_plan
    sb = builder
    sb.tool_started(tool_id: 't1', name: 'Read', summary: 'docs/huge.md')
    sb.tool_finished(tool_id: 't1')
    sb.set_todos([{ 'content' => 'Finish the parser', 'status' => 'pending' }])

    preamble = record(builder: sb).preamble

    assert_includes preamble, 'Read: docs/huge.md'
    assert_includes preamble, 'Finish the parser'
  end

  # Empty git/action data must not leave dangling "- branch:" labels in the prompt.
  def test_preamble_omits_labels_without_data
    note = McptaskRunner::TaskHandoff.new('overflow_count' => 1, 'updated_at' => '2026-08-06T08:44:12.000Z',
                                          'branch' => '', 'commits' => [], 'uncommitted' => [],
                                          'recent_actions' => [], 'open_todos' => [])

    refute_match(/- branch:/, note.preamble)
    refute_match(/- commits on branch:/, note.preamble)
    assert_match(/REPEAT ATTEMPT/, note.preamble)
  end

  def test_record_captures_on_disk_git_state
    system('git', 'init', '--quiet', @tmp, out: File::NULL, err: File::NULL)
    File.write(File.join(@tmp, 'touched.rb'), "# wip\n")

    note = record.data

    assert_includes note['uncommitted'].join(' '), 'touched.rb', 'uncommitted work is what the next attempt must not redo'
  end
end
