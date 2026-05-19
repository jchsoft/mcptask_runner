# frozen_string_literal: true

require 'test_helper'

class SnapshotBuilderTest < Minitest::Test
  def setup
    @builder = McptaskRunner::SnapshotBuilder.new(
      session_id: "sess-uuid-123",
      machine_id: "test-machine"
    )
  end

  # ---- Initialization ----

  def test_initial_snapshot_fields
    h = @builder.to_h
    assert_equal 1,              h[:schema_version]
    assert_equal "sess-uuid-123", h[:session_id]
    assert_equal "test-machine",  h[:machine_id]
    assert_equal "starting",      h[:status]
    assert_nil   h[:task_id]
    assert_nil   h[:task_name]
    assert_nil   h[:model]
    assert_nil   h[:quota]
    assert_nil   h[:error_message]
    assert_nil   h[:closed_at]
    assert_nil   h[:ttl_seconds]
    assert_equal [], h[:active_actions]
  end

  def test_to_h_returns_frozen_hash
    assert_predicate @builder.to_h, :frozen?
  end

  # ---- set_task ----

  def test_set_task_stores_id_and_name
    @builder.set_task(task_id: 42, task_name: "Fix bug")
    h = @builder.to_h
    assert_equal 42,        h[:task_id]
    assert_equal "Fix bug", h[:task_name]
  end

  # ---- set_model ----

  def test_set_model_stored
    @builder.set_model("claude-sonnet-4-6")
    assert_equal "claude-sonnet-4-6", @builder.to_h[:model]
  end

  # ---- set_todos ----

  def test_todo_list_initially_empty
    assert_equal [], @builder.to_h[:todo_list]
  end

  def test_set_todos_normalizes_entries
    @builder.set_todos([
      { content: "Plan", status: "completed", activeForm: "Planning" },
      { "content" => "Code", "status" => "in_progress", "activeForm" => "Coding" }
    ])
    list = @builder.to_h[:todo_list]
    assert_equal 2, list.size
    assert_equal "Plan", list[0][:content]
    assert_equal "completed", list[0][:status]
    assert_equal "Coding", list[1][:activeForm]
  end

  def test_set_todos_drops_entries_without_content
    @builder.set_todos([{ content: nil, status: "pending" }, { content: "Real", status: "pending" }])
    list = @builder.to_h[:todo_list]
    assert_equal 1, list.size
    assert_equal "Real", list[0][:content]
  end

  def test_set_todos_defaults_unknown_status_to_pending
    @builder.set_todos([{ content: "X", status: "weird" }])
    assert_equal "pending", @builder.to_h[:todo_list][0][:status]
  end

  def test_set_todos_with_nil_clears_list
    @builder.set_todos([{ content: "X", status: "pending" }])
    @builder.set_todos(nil)
    assert_equal [], @builder.to_h[:todo_list]
  end

  # ---- set_quota ----

  def test_set_quota_stored
    @builder.set_quota(per_day_hours: 8, already_worked_hours: 2.5)
    q = @builder.to_h[:quota]
    assert_equal 8.0, q[:per_day_hours]
    assert_equal 2.5, q[:already_worked_hours]
  end

  # ---- Status transitions ----

  def test_valid_transition_starting_to_triage
    @builder.set_status("triage")
    assert_equal "triage", @builder.to_h[:status]
  end

  def test_valid_transition_triage_to_processing
    @builder.set_status("triage")
    @builder.set_status("processing")
    assert_equal "processing", @builder.to_h[:status]
  end

  def test_valid_happy_path_full_cycle
    @builder.set_status("triage")
    @builder.set_status("processing")
    @builder.set_status("waiting")
    @builder.set_status("processing")
    @builder.set_status("finished")
    @builder.set_status("closed")
    assert_equal "closed", @builder.to_h[:status]
  end

  def test_valid_stalled_path
    @builder.set_status("triage")
    @builder.set_status("processing")
    @builder.set_status("stalled")
    @builder.set_status("processing")
    assert_equal "processing", @builder.to_h[:status]
  end

  def test_invalid_transition_raises
    assert_raises(McptaskRunner::InvalidTransitionError) do
      @builder.set_status("processing") # starting → processing is invalid
    end
  end

  def test_invalid_transition_finished_to_processing_raises
    @builder.set_status("triage")
    @builder.set_status("processing")
    @builder.set_status("finished")
    assert_raises(McptaskRunner::InvalidTransitionError) do
      @builder.set_status("processing")
    end
  end

  # Loop iteration may re-enter triage when the prior task did not formally finish:
  # story_loop iter 1 reuses the WorkLoop builder; if the executor crashed before its
  # processing → finished transition guard, iter 2 still legitimately triages a new task.
  def test_loop_reset_processing_to_triage_allowed
    @builder.set_status("triage")
    @builder.set_status("processing")
    @builder.set_status("triage")
    assert_equal "triage", @builder.to_h[:status]
  end

  def test_loop_reset_stalled_to_triage_allowed
    @builder.set_status("triage")
    @builder.set_status("processing")
    @builder.set_status("stalled")
    @builder.set_status("triage")
    assert_equal "triage", @builder.to_h[:status]
  end

  def test_any_state_can_transition_to_frozen
    @builder.set_status("frozen")
    assert_equal "frozen", @builder.to_h[:status]
  end

  def test_any_state_can_transition_to_closed
    @builder.set_status("closed")
    assert_equal "closed", @builder.to_h[:status]
  end

  def test_closed_cannot_transition_further
    @builder.set_status("closed")
    assert_raises(McptaskRunner::InvalidTransitionError) do
      @builder.set_status("triage")
    end
  end

  def test_set_status_stores_error_message
    @builder.set_status("triage")
    @builder.set_status("error", error_message: "Context overflow")
    h = @builder.to_h
    assert_equal "error",             h[:status]
    assert_equal "Context overflow",  h[:error_message]
  end

  def test_set_status_clears_error_message_when_nil
    @builder.set_status("triage")
    @builder.set_status("error", error_message: "boom")
    @builder.set_status("closed") # any → closed, clears error_message
    assert_nil @builder.to_h[:error_message]
  end

  # ---- Active actions ----

  def test_tool_started_appears_in_active_actions
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: "bin/rails test")
    actions = @builder.to_h[:active_actions]
    assert_equal 1,           actions.length
    action = actions.first
    assert_equal "t1",         action[:tool_id]
    assert_equal "Bash",       action[:name]
    assert_equal "bin/rails test", action[:summary]
    assert_respond_to action[:elapsed_s], :round
    refute_nil action[:started_at]
  end

  def test_tool_finished_removes_from_active_actions
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: "bin/rails test")
    @builder.tool_finished(tool_id: "t1")
    assert_empty @builder.to_h[:active_actions]
  end

  def test_multiple_tools_tracked_independently
    @builder.tool_started(tool_id: "t1", name: "Bash",  summary: "cmd1")
    @builder.tool_started(tool_id: "t2", name: "Read",  summary: "path/to/file")
    @builder.tool_finished(tool_id: "t1")
    actions = @builder.to_h[:active_actions]
    assert_equal 1,    actions.length
    assert_equal "t2", actions.first[:tool_id]
  end

  def test_summary_truncated_to_120_chars
    long_summary = "x" * 200
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: long_summary)
    action = @builder.to_h[:active_actions].first
    assert_equal 120, action[:summary].length
  end

  # ---- close / tombstone ----

  def test_close_sets_status_and_tombstone_fields
    @builder.close(ttl_seconds: 30)
    h = @builder.to_h
    assert_equal "closed", h[:status]
    assert_equal 30,       h[:ttl_seconds]
    refute_nil             h[:closed_at]
  end

  def test_close_default_ttl
    @builder.close
    assert_equal 60, @builder.to_h[:ttl_seconds]
  end

  def test_close_clears_error_message
    @builder.set_status("triage")
    @builder.set_status("error", error_message: "boom")
    @builder.close
    assert_nil @builder.to_h[:error_message]
  end

  # ---- mark_activity ----

  def test_mark_activity_updates_last_activity_at
    before = @builder.to_h[:last_activity_at]
    sleep 0.01
    @builder.mark_activity
    after = @builder.to_h[:last_activity_at]
    assert after >= before
  end

  # ---- schema contract compliance ----

  def test_to_h_keys_match_schema_contract
    required_keys = %i[
      schema_version session_id machine_id task_id task_name
      status model active_actions last_activity_at error_message
      quota closed_at ttl_seconds updated_at
    ]
    h = @builder.to_h
    required_keys.each do |key|
      assert h.key?(key), "Missing key: #{key}"
    end
  end

  # ---- public query helpers ----

  def test_status_reader
    assert_equal "starting", @builder.status
    @builder.set_status(:triage)
    assert_equal "triage", @builder.status
  end

  def test_active_tool_count_empty
    assert_equal 0, @builder.active_tool_count
  end

  def test_active_tool_count_with_tools
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: "ls")
    @builder.tool_started(tool_id: "t2", name: "Read", summary: "file.rb")
    assert_equal 2, @builder.active_tool_count
    @builder.tool_finished(tool_id: "t1")
    assert_equal 1, @builder.active_tool_count
  end

  def test_has_active_tools_false_when_empty
    refute @builder.has_active_tools?
  end

  def test_has_active_tools_true_when_present
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: "ls")
    assert @builder.has_active_tools?
  end

  def test_active_tool_names
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: "ls")
    @builder.tool_started(tool_id: "t2", name: "Read", summary: "f.rb")
    assert_equal %w[Bash Read], @builder.active_tool_names.sort
  end

  def test_format_active_tools_empty
    assert_equal "", @builder.format_active_tools
  end

  def test_format_active_tools_with_tool
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @builder.instance_variable_get(:@active_actions)["t1"] = {
      name: "Bash", summary: "ls", mono_started_at: now - 30, started_at: Time.now.utc.iso8601(3)
    }
    result = @builder.format_active_tools(now)
    assert_includes result, "waiting for:"
    assert_includes result, "Bash since 30s"
  end

  def test_active_actions_snapshot_returns_copy
    @builder.tool_started(tool_id: "t1", name: "Bash", summary: "ls")
    snap = @builder.active_actions_snapshot
    assert_equal 1, snap.size
    snap.delete("t1")
    assert_equal 1, @builder.active_tool_count, "Snapshot is a copy, original unchanged"
  end

  # ---- full state cycle integration ----

  def test_full_session_state_cycle
    emitted = []
    record = ->(snap, force: false) { emitted << snap[:status] }

    McptaskRunner::EventStream.stub(:emit_snapshot, record) do
      # Simulate WorkLoop.execute start
      McptaskRunner::EventStream.stub(:builder, @builder) do
        # starting → emit
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
        assert_equal "starting", emitted.last

        # triage
        @builder.set_status(:triage)
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
        assert_equal "triage", emitted.last

        # triage completes: model + task + processing
        @builder.set_model("claude-opus-4-7")
        @builder.set_task(task_id: 9999, task_name: "Fix bug")
        @builder.set_status(:processing)
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
        assert_equal "processing", emitted.last
        assert_equal "claude-opus-4-7", @builder.to_h[:model]
        assert_equal 9999, @builder.to_h[:task_id]

        # tool events during execution
        @builder.tool_started(tool_id: "t1", name: "Bash", summary: "rspec")
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h)
        assert_equal 1, @builder.active_tool_count

        @builder.tool_finished(tool_id: "t1")
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h)
        assert_equal 0, @builder.active_tool_count

        # execution finishes
        @builder.set_status(:finished)
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
        assert_equal "finished", emitted.last

        # WorkLoop ensure: close
        @builder.close
        McptaskRunner::EventStream.emit_snapshot(@builder.to_h, force: true)
        assert_equal "closed", emitted.last
      end
    end

    assert_equal %w[starting triage processing processing processing finished closed], emitted
  end
end
