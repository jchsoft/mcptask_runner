# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseRetryTest < Minitest::Test
  # Named (not anonymous) so self.class.name is non-nil in ClaudeCodeBase#initialize.
  class StubAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
    def result_json_fields = '"status": "success", "pr_number": N'
  end

  def test_stream_closed_error_exists
    assert_kind_of Class, McptaskRunner::StreamClosedError
    assert McptaskRunner::StreamClosedError < StandardError
  end

  def test_stream_closed_error_can_be_raised_with_message
    error = McptaskRunner::StreamClosedError.new('test error message')
    assert_equal 'test error message', error.message
  end

  def test_missing_marker_error_exists
    assert_kind_of Class, McptaskRunner::MissingMarkerError
    assert McptaskRunner::MissingMarkerError < StandardError
  end

  def test_missing_marker_error_can_be_raised_with_message
    error = McptaskRunner::MissingMarkerError.new('marker not found')
    assert_equal 'marker not found', error.message
  end

  def test_handle_recoverable_error_returns_nil_for_retry
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 0
    start_time = Time.now

    result = base.send(:handle_recoverable_error, 'Timeout', start_time)

    assert_nil result, 'Should return nil to signal retry'
  end

  def test_handle_recoverable_error_returns_error_when_max_retries_reached
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 2 # MAX_RETRY_ATTEMPTS - 1
    start_time = Time.now

    result = base.send(:handle_recoverable_error, 'Timeout', start_time)

    assert_equal 'error', result['status']
    assert_match(/retries exhausted/, result['message'])
  end

  def test_handle_marker_retry_returns_nil_for_retry
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 0
    start_time = Time.now

    result = base.send(:handle_marker_retry, start_time)

    assert_nil result, 'Should return nil to signal retry'
  end

  def test_handle_marker_retry_sets_marker_retry_mode
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 0
    start_time = Time.now

    base.send(:handle_marker_retry, start_time)

    assert base.instance_variable_get(:@retry_state).marker_retry_mode, 'Should set marker_retry_mode to true'
  end

  def test_handle_marker_retry_returns_error_when_max_retries_reached
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@retry_state).count = 2 # MAX_RETRY_ATTEMPTS - 1
    start_time = Time.now

    result = base.send(:handle_marker_retry, start_time)

    assert_equal 'error', result['status']
    assert_match(/Missing TASKRUNNER_RESULT/, result['message'])
    assert_match(/retries exhausted/, result['message'])
  end

  def test_build_continuation_instructions_contains_retry_guidance
    base = McptaskRunner::ClaudeCodeBase.new

    instructions = base.send(:build_continuation_instructions)

    assert_includes instructions, 'previous session was interrupted'
    assert_includes instructions, 'Check what you already completed'
    assert_includes instructions, 'git status'
    assert_includes instructions, 'Continue from where you left off'
    assert_includes instructions, 'Complete ALL remaining steps'
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'Do NOT just output the marker'
  end

  # The whole point of the continuation prompt: --continue already replays the full workflow into
  # context, so it must NOT re-embed build_instructions (that would duplicate the done steps).
  def test_build_continuation_instructions_omits_full_workflow
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:build_instructions) { "Step 1: Do this\nStep 2: Do that\n" * 50 }

    instructions = base.send(:build_continuation_instructions)

    refute_includes instructions, 'Step 1: Do this', 'continuation must NOT re-embed the full workflow'
    refute_includes instructions, 'ORIGINAL WORKFLOW'
    assert_operator instructions.length, :<, base.send(:build_instructions).length,
                    'continuation must be shorter than full instructions'
    assert_includes instructions, 'TASKRUNNER_RESULT'
  end

  def test_continuation_result_contract_default_is_generic_reference
    contract = McptaskRunner::ClaudeCodeBase.new.send(:continuation_result_contract)

    assert_includes contract, 'TASKRUNNER_RESULT'
    assert_includes contract, 'specified earlier'
  end

  # auto_squash overrides the contract to reproduce the exact result-format block so a resumed
  # session can't forget the marker.
  def test_autosquash_continuation_contract_reproduces_result_format
    contract = StubAutoSquash.new.send(:continuation_result_contract)

    assert_includes contract, 'TASKRUNNER_RESULT'
    assert_includes contract, '"status": "success"'
    assert_includes contract, '```json'
  end

  # Regression (mcptask #11358): a fresh-session restart resumes the SAME task without passing
  # through triage — the only other place that re-sets :processing — so the card stayed terminal
  # for the whole restarted attempt. mcptask.online showed "Finished" and closed the card while
  # the runner worked on for another 20+ minutes.
  def test_reopen_snapshot_for_retry_reopens_finished_card
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:processing)
    builder.set_status(:finished)

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snapshot, **_kw) { emitted << snapshot }) do
      base.send(:reopen_snapshot_for_retry)
    end

    assert_equal 'processing', builder.status, 'retried attempt must re-open the card the dead attempt closed'
    assert_equal 'processing', emitted.last[:status], 'web UI must be told immediately, not on the next heartbeat'
  end

  # Overflow / tool-not-enabled watchdogs end the dead attempt at :error, so the restart has to
  # re-open from there too.
  def test_reopen_snapshot_for_retry_reopens_error_card
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:processing)
    builder.set_status(:error, error_message: 'Context overflow')

    base.send(:reopen_snapshot_for_retry)

    assert_equal 'processing', builder.status
    assert_nil builder.to_h[:error_message], 're-opening must clear the dead attempt\'s error message'
  end

  # Non-terminal statuses belong to the live session (triage hop, first attempt of a task) —
  # re-opening them would be a spurious transition, and starting → processing would mislabel triage.
  def test_reopen_snapshot_for_retry_leaves_non_terminal_status_untouched
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:triage)

    emitted = []
    McptaskRunner::EventStream.stub(:emit_snapshot, ->(snapshot, **_kw) { emitted << snapshot }) do
      base.send(:reopen_snapshot_for_retry)
    end

    assert_equal 'triage', builder.status
    assert_empty emitted, 'must not emit a snapshot when nothing changed'
  end

  # End-to-end on the real funnel: every attempt goes through attempt_execution, so the card is
  # live again before the child is even forked.
  def test_attempt_execution_reopens_terminal_card_before_forking
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'sonnet' }
    base.define_singleton_method(:build_instructions) { 'noop' }
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.set_status(:processing)
    builder.set_status(:error, error_message: 'Context overflow')
    base.instance_variable_get(:@retry_state).fresh_restart = true
    base.instance_variable_set(:@accumulated_output, +'')

    status_at_fork = nil
    base.stub(:build_command, ->(_b, _i, continue_session: false) { status_at_fork = builder.status; [] }) do
      base.stub(:execute_with_streaming, '') do
        base.stub(:parse_result, { 'status' => 'success' }) do
          base.instance_variable_get(:@state).result_received = true
          base.send(:attempt_execution, Time.now)
        end
      end
    end

    assert_equal 'processing', status_at_fork, 'card must be re-opened before the restarted child starts'
  end
end
