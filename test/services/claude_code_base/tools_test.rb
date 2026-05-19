# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseToolsTest < Minitest::Test
  def test_track_tool_event_adds_tool_use
    base = McptaskRunner::ClaudeCodeBase.new
    line = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool_123","name":"Skill","input":{}}]}}'

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) { base.send(:track_tool_event, line) }

    builder = base.instance_variable_get(:@snapshot_builder)
    assert_equal 1, builder.active_tool_count
    assert_includes builder.active_tool_names, 'Skill'
  end

  def test_track_tool_event_removes_on_tool_result
    base = McptaskRunner::ClaudeCodeBase.new
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.tool_started(tool_id: 'tool_123', name: 'Skill', summary: '')

    line = '{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tool_123","content":"ok"}]}}'
    McptaskRunner::EventStream.stub(:emit_snapshot, nil) { base.send(:track_tool_event, line) }

    assert_equal 0, builder.active_tool_count
  end

  def test_track_tool_event_captures_todos_from_todowrite
    base = McptaskRunner::ClaudeCodeBase.new
    todos = [
      { content: "Plan", status: "completed", activeForm: "Planning" },
      { content: "Code", status: "in_progress", activeForm: "Coding" }
    ]
    line = JSON.generate(
      type: "assistant",
      message: { content: [{ type: "tool_use", id: "todo_1", name: "TodoWrite", input: { todos: todos } }] }
    )

    McptaskRunner::EventStream.stub(:emit_snapshot, nil) { base.send(:track_tool_event, line) }

    todo_list = base.instance_variable_get(:@snapshot_builder).to_h[:todo_list]
    assert_equal 2, todo_list.size
    assert_equal "Plan", todo_list[0][:content]
    assert_equal "in_progress", todo_list[1][:status]
  end

  def test_track_tool_event_ignores_non_json
    base = McptaskRunner::ClaudeCodeBase.new
    McptaskRunner::EventStream.stub(:emit_snapshot, nil) { base.send(:track_tool_event, 'not json at all') }
    assert_equal 0, base.instance_variable_get(:@snapshot_builder).active_tool_count
  end

  def test_track_tool_event_ignores_lines_without_content
    base = McptaskRunner::ClaudeCodeBase.new
    McptaskRunner::EventStream.stub(:emit_snapshot, nil) { base.send(:track_tool_event, '{"type":"result","cost_usd":0.05}') }
    assert_equal 0, base.instance_variable_get(:@snapshot_builder).active_tool_count
  end

  def test_format_active_tools_empty
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal '', base.send(:format_active_tools)
  end

  def test_format_active_tools_with_tools
    base = McptaskRunner::ClaudeCodeBase.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    builder = base.instance_variable_get(:@snapshot_builder)
    builder.instance_variable_get(:@active_actions)['tool_1'] = {
      name: 'Skill', summary: '', mono_started_at: now - 300, started_at: Time.now.utc.iso8601(3)
    }

    result = base.send(:format_active_tools, now)
    assert_includes result, 'waiting for:'
    assert_includes result, 'Skill since 300s'
  end

  # Tests for per-tool hang timeout — fast tools (MCP, Read/Edit/Grep) get a shorter ceiling than
  # long tools (Bash/Task running tests, CI, subagents). Catches MCP server hangs without
  # waiting the full 60min long-tool ceiling.
  def test_quick_tool_hang_timeout_constant_is_defined
    assert_equal 120, McptaskRunner::ClaudeCodeBase::QUICK_TOOL_HANG_TIMEOUT
  end

  def test_long_running_tools_constant_includes_bash_and_task
    assert_includes McptaskRunner::ClaudeCodeBase::LONG_RUNNING_TOOLS, 'Bash'
    assert_includes McptaskRunner::ClaudeCodeBase::LONG_RUNNING_TOOLS, 'Task'
  end

  def test_tool_hang_timeout_for_bash_uses_long_ceiling
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal McptaskRunner::ClaudeCodeBase::TOOL_HANG_TIMEOUT,
                 base.send(:tool_hang_timeout_for, 'Bash')
  end

  def test_tool_hang_timeout_for_task_uses_long_ceiling
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal McptaskRunner::ClaudeCodeBase::TOOL_HANG_TIMEOUT,
                 base.send(:tool_hang_timeout_for, 'Task')
  end

  def test_tool_hang_timeout_for_mcp_tool_uses_quick_ceiling
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal McptaskRunner::ClaudeCodeBase::QUICK_TOOL_HANG_TIMEOUT,
                 base.send(:tool_hang_timeout_for, 'mcp__mcptask-online__LogWorkProgressTool')
  end

  def test_tool_hang_timeout_for_read_uses_quick_ceiling
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal McptaskRunner::ClaudeCodeBase::QUICK_TOOL_HANG_TIMEOUT,
                 base.send(:tool_hang_timeout_for, 'Read')
  end

  def test_hung_tool_returns_nil_when_no_active_tools
    base = McptaskRunner::ClaudeCodeBase.new
    assert_nil base.send(:hung_tool, Process.clock_gettime(Process::CLOCK_MONOTONIC))
  end

  def test_hung_tool_returns_nil_when_quick_tool_within_limit
    base = McptaskRunner::ClaudeCodeBase.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    base.instance_variable_get(:@snapshot_builder).instance_variable_get(:@active_actions)['id1'] = {
      name: 'mcp__mcptask-online__LogWorkProgressTool', summary: '', mono_started_at: now - 60, started_at: Time.now.utc.iso8601(3)
    }
    assert_nil base.send(:hung_tool, now)
  end

  def test_hung_tool_detects_quick_tool_past_quick_limit
    base = McptaskRunner::ClaudeCodeBase.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    base.instance_variable_get(:@snapshot_builder).instance_variable_get(:@active_actions)['id1'] = {
      name: 'mcp__mcptask-online__LogWorkProgressTool', summary: '', mono_started_at: now - 200, started_at: Time.now.utc.iso8601(3)
    }
    hung = base.send(:hung_tool, now)
    refute_nil hung, 'Quick MCP tool stuck >120s should be flagged hung'
    assert_equal 'mcp__mcptask-online__LogWorkProgressTool', hung[:name]
  end

  def test_hung_tool_ignores_bash_within_long_limit
    base = McptaskRunner::ClaudeCodeBase.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    base.instance_variable_get(:@snapshot_builder).instance_variable_get(:@active_actions)['id1'] = {
      name: 'Bash', summary: '', mono_started_at: now - 1500, started_at: Time.now.utc.iso8601(3)
    }
    assert_nil base.send(:hung_tool, now), 'Bash within long ceiling must not be flagged'
  end

  def test_hung_tool_detects_bash_past_long_limit
    base = McptaskRunner::ClaudeCodeBase.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    base.instance_variable_get(:@snapshot_builder).instance_variable_get(:@active_actions)['id1'] = {
      name: 'Bash', summary: '', mono_started_at: now - 3700, started_at: Time.now.utc.iso8601(3)
    }
    refute_nil base.send(:hung_tool, now), 'Bash past 60min ceiling should be flagged'
  end

  def test_hung_tool_picks_quick_tool_over_long_bash
    base = McptaskRunner::ClaudeCodeBase.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actions = base.instance_variable_get(:@snapshot_builder).instance_variable_get(:@active_actions)
    actions['bash1'] = { name: 'Bash', summary: '', mono_started_at: now - 1200, started_at: Time.now.utc.iso8601(3) }
    actions['mcp1'] = { name: 'mcp__mcptask-online__AddMessageTool', summary: '', mono_started_at: now - 180, started_at: Time.now.utc.iso8601(3) }
    hung = base.send(:hung_tool, now)
    refute_nil hung
    assert_equal 'mcp__mcptask-online__AddMessageTool', hung[:name]
  end
end
