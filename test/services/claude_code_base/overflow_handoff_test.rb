# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

# Cross-run recovery from context overflow: the terminal error only ends ONE runner process, so
# the overflow is persisted as a TaskHandoff note and replayed as a prompt preamble the next time
# the same task_id comes back. See ClaudeCodeBase#attempt_preamble / #finalize_task_handoff.
class ClaudeCodeBaseOverflowHandoffTest < Minitest::Test
  TASK_ID = 11_291

  def setup
    @orig_dir = Dir.pwd
    @tmp = Dir.mktmpdir
    Dir.chdir(@tmp)
  end

  def teardown
    Dir.chdir(@orig_dir)
    FileUtils.remove_entry(@tmp)
  end

  # A base wired to a specific task, as every task-working executor is.
  def base_for_task
    McptaskRunner::ClaudeCodeBase.new.tap do |base|
      base.instance_variable_set(:@task_id, TASK_ID)
      base.define_singleton_method(:model_name) { 'sonnet' }
      base.define_singleton_method(:build_instructions) { 'FULL WORKFLOW' }
      base.instance_variable_set(:@accumulated_output, +'')
    end
  end

  # Capture the instructions attempt_execution hands to build_command.
  def captured_instructions(base)
    captured = nil
    capture = ->(_cmd, instructions, continue_session: false) { captured = instructions; [] }
    base.stub(:build_command, capture) do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, { 'status' => 'success' }) do
          base.instance_variable_get(:@state).result_received = true
          base.send(:attempt_execution, Time.now)
        end
      end
    end
    captured
  end

  def existing_note
    McptaskRunner::TaskHandoff.load(TASK_ID)
  end

  def test_terminal_overflow_persists_a_note_for_the_task
    base = base_for_task
    base.instance_variable_get(:@retry_state).overflow_restart_count =
      McptaskRunner::Concerns::RetryHandling::MAX_OVERFLOW_RESTARTS

    result = base.send(:handle_context_overflow, Time.now - 900)

    assert_equal 'context_overflow', result['reason']
    assert_equal 1, existing_note.overflow_count, 'the terminal must leave a note for the next runner cycle'
    assert_equal TASK_ID, existing_note.data['task_id']
  end

  # The in-process fresh restart records too: if the runner process itself dies (quota, launcher
  # restart) before the restart finishes, the note is still the only thing that survives.
  def test_fresh_restart_overflow_also_persists_a_note
    base = base_for_task

    assert_nil base.send(:handle_context_overflow, Time.now - 900)
    assert_equal 1, existing_note.overflow_count
    refute existing_note.data['terminal'], 'a recoverable overflow is recorded as non-terminal'
  end

  def test_first_attempt_prepends_prior_overflow_preamble
    record_note
    instructions = captured_instructions(base_for_task)

    assert_match(/REPEAT ATTEMPT/, instructions, 'a repeat attempt must be told it is one')
    assert_match(/CONTEXT BUDGET/, instructions)
    assert_includes instructions, 'FULL WORKFLOW', 'the full workflow must still be sent'
  end

  def test_first_attempt_unchanged_without_a_note
    assert_equal 'FULL WORKFLOW', captured_instructions(base_for_task),
                 'no note = normal run, instructions byte-for-byte unchanged'
  end

  # A --continue retry resumes a session that already carries everything; re-stating the handoff
  # would just re-bloat the context it is recovering from.
  def test_continue_retry_does_not_prepend_prior_overflow_preamble
    record_note
    base = base_for_task
    base.instance_variable_get(:@retry_state).count = 1

    refute_match(/REPEAT ATTEMPT/, captured_instructions(base))
  end

  # The in-process fresh restart uses its own live action trail, not the disk note it just wrote.
  def test_fresh_restart_uses_live_trail_not_the_note
    record_note
    base = base_for_task
    base.instance_variable_get(:@retry_state).fresh_restart = true
    sb = base.instance_variable_get(:@snapshot_builder)
    sb.tool_started(tool_id: 't1', name: 'Bash', summary: 'bin/ci')
    sb.tool_finished(tool_id: 't1')

    instructions = captured_instructions(base)

    assert_match(/ran out of context/, instructions)
    refute_match(/REPEAT ATTEMPT/, instructions, 'must not stack both preambles')
  end

  def test_run_clears_the_note_when_the_run_does_not_overflow
    record_note
    base = base_for_task
    base.stub(:run_with_retry, { 'status' => 'success' }) { base.run }

    assert_nil existing_note, 'a run that got through must not leave the next one thinking it is a repeat'
  end

  def test_run_keeps_the_note_on_a_context_overflow_terminal
    record_note
    base = base_for_task
    terminal = { 'status' => 'error', 'reason' => 'context_overflow', 'message' => 'overflowed' }
    base.stub(:run_with_retry, terminal) { base.run }

    refute_nil existing_note, 'the note is exactly what the next runner cycle needs'
  end

  private

  def record_note
    McptaskRunner::TaskHandoff.record_overflow(
      McptaskRunner::TaskHandoff::Overflow.new(task_id: TASK_ID, mode: 'TodayAutoSquash', elapsed_s: 946.9,
                                              terminal: true, message: 'Context overflow after 0.26h'),
      snapshot_builder_for_task
    )
  end

  def snapshot_builder_for_task
    McptaskRunner::SnapshotBuilder.new(session_id: 'sess-1', machine_id: 'mac', project_name: 'projectoid_ii').tap do |sb|
      sb.set_task(task_id: TASK_ID, task_name: 'Business-value features')
      sb.set_model('kimi-k2.7-code:cloud')
    end
  end
end
