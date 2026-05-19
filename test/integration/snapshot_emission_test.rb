# frozen_string_literal: true

require 'test_helper'

# Integration test: SnapshotBuilder + EventStream + StreamProcessing work together.
# No real WebSocket is opened — EventStream.emit_snapshot is stubbed to capture emissions.
class SnapshotEmissionTest < Minitest::Test
  def setup
    @builder = McptaskRunner::SnapshotBuilder.new(session_id: 'e2e-sess-001', machine_id: 'e2e-box')
    @emitted = []
    @capture = ->( snap, **_kw) { @emitted << snap.dup }
  end

  # ---- Full state cycle ----

  def test_full_state_cycle_emits_snapshots_in_order
    McptaskRunner::EventStream.stub(:emit_snapshot, @capture) do
      # WorkLoop.execute bootstraps with starting emit
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)

      @builder.set_status(:triage)
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)

      @builder.set_task(task_id: 9999, task_name: 'Fix failing tests')
      @builder.set_status(:processing)
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)

      @builder.set_status(:finished)
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)

      # WorkLoop.execute ensure block
      @builder.close(ttl_seconds: 60)
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
    end

    statuses = @emitted.map { |s| s[:status] }
    assert_equal 'starting',    statuses[0]
    assert_equal 'triage',      statuses[1]
    assert_equal 'processing',  statuses[2]
    assert_equal 'finished',    statuses[3]
    assert_equal 'closed',      statuses[4]
  end

  # ---- Processing snapshot includes active_actions ----

  def test_processing_snapshot_carries_active_actions
    McptaskRunner::EventStream.stub(:emit_snapshot, @capture) do
      @builder.set_status(:triage)
      @builder.set_task(task_id: 9999, task_name: 'Fix failing tests')
      @builder.set_status(:processing)

      @builder.tool_started(tool_id: 'toolu_001', name: 'Grep', summary: 'User')
      @builder.tool_started(tool_id: 'toolu_002', name: 'Edit', summary: 'file.rb')
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
    end

    snap = @emitted.last
    assert_equal 'processing', snap[:status]
    assert_equal 2, snap[:active_actions].length

    names = snap[:active_actions].map { |a| a[:name] }.sort
    assert_equal %w[Edit Grep], names

    grep = snap[:active_actions].find { |a| a[:name] == 'Grep' }
    edit = snap[:active_actions].find { |a| a[:name] == 'Edit' }
    assert_equal 'User',    grep[:summary]
    assert_equal 'file.rb', edit[:summary]
  end

  # ---- Tool events from scripted Claude stdout ----

  def test_tool_events_from_scripted_stdout_populate_and_clear_active_actions
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@snapshot_builder, @builder)
    base.instance_variable_set(:@stall_detector, nil)

    grep_use = JSON.generate(
      type: 'assistant',
      message: { content: [
        { type: 'tool_use', id: 'toolu_001', name: 'Grep', input: { pattern: 'User', path: 'app/' } }
      ] }
    )

    edit_use = JSON.generate(
      type: 'assistant',
      message: { content: [
        { type: 'tool_use', id: 'toolu_002', name: 'Edit', input: { file_path: 'app/models/user.rb' } }
      ] }
    )

    grep_result = JSON.generate(
      type: 'tool',
      message: { content: [
        { type: 'tool_result', tool_use_id: 'toolu_001', content: 'Found 3 matches' }
      ] }
    )

    McptaskRunner::EventStream.stub(:emit_snapshot, @capture) do
      @builder.set_status(:triage)
      @builder.set_task(task_id: 9999, task_name: 'Fix tests')
      @builder.set_status(:processing)

      base.send(:track_tool_event, grep_use)
      base.send(:track_tool_event, edit_use)

      assert_equal 2, @builder.active_tool_count
      assert_equal %w[Edit Grep], @builder.active_tool_names.sort

      base.send(:track_tool_event, grep_result)

      assert_equal 1, @builder.active_tool_count
      assert_equal 'Edit', @builder.active_tool_names.first
    end

    # emit_snapshot called for each tool_use and tool_result event
    assert @emitted.length >= 3, "Expected ≥ 3 emit calls: 2 tool_use + 1 tool_result"
  end

  # ---- Frozen snapshot carries error_message ----

  def test_frozen_snapshot_carries_error_message
    McptaskRunner::EventStream.stub(:emit_snapshot, @capture) do
      @builder.set_status(:triage)
      @builder.set_status(:processing)
      @builder.set_status(:frozen, error_message: 'Runner stopped responding')
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
    end

    snap = @emitted.last
    assert_equal 'frozen',                    snap[:status]
    assert_equal 'Runner stopped responding', snap[:error_message]
  end

  # ---- Closed snapshot carries ttl_seconds + closed_at ----

  def test_closed_snapshot_carries_ttl_and_closed_at
    McptaskRunner::EventStream.stub(:emit_snapshot, @capture) do
      @builder.set_status(:triage)
      @builder.set_status(:processing)
      @builder.set_status(:finished)
      @builder.close(ttl_seconds: 2)
      McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
    end

    snap = @emitted.last
    assert_equal 'closed', snap[:status]
    assert_equal 2,        snap[:ttl_seconds]
    refute_nil             snap[:closed_at]
  end
end
