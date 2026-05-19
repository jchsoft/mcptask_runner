# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseParsingTest < Minitest::Test
  def test_find_json_end_with_simple_json
    base = McptaskRunner::ClaudeCodeBase.new
    json_str = '{"status": "success"}'
    json_end = base.send(:find_json_end, json_str)
    assert_equal json_str.length, json_end
  end

  def test_find_json_end_with_nested_json
    base = McptaskRunner::ClaudeCodeBase.new
    json_str = '{"status": "success", "data": {"nested": "value"}}'
    json_end = base.send(:find_json_end, json_str)
    assert_equal json_str.length, json_end
  end

  def test_find_json_end_handles_escaped_quotes
    base = McptaskRunner::ClaudeCodeBase.new
    json_str = '{"text": "He said \\"hello\\"", "status": "done"}'
    json_end = base.send(:find_json_end, json_str)
    assert_equal json_str.length, json_end
  end

  def test_find_json_end_returns_nil_for_unclosed_json
    base = McptaskRunner::ClaudeCodeBase.new
    json_str = '{"status": "success"'
    json_end = base.send(:find_json_end, json_str)
    assert_nil json_end
  end

  def test_parse_result_returns_parsed_json_with_task_worked
    mock_output = 'TASKRUNNER_RESULT: {"status": "success", "hours": {"per_day": 8, "task_estimated": 2}}'
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:parse_result, mock_output, 1.5)

    assert_equal 'success', result['status']
    assert_equal 8, result['hours']['per_day']
    assert_equal 2, result['hours']['task_estimated']
    assert_equal 1.5, result['hours']['task_worked']
  end

  def test_parse_result_handles_error_when_result_not_found
    mock_output = 'Some output without JSON'
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:parse_result, mock_output, 0.5)

    assert_equal 'error', result['status']
    assert_equal 'No TASKRUNNER_RESULT found in output', result['message']
  end

  def test_parse_result_handles_invalid_json
    mock_output = 'TASKRUNNER_RESULT: {invalid json}'
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:parse_result, mock_output, 0.5)

    assert_equal 'error', result['status']
    assert_match(/Failed to parse JSON/, result['message'])
  end

  def test_parse_result_handles_json_with_escaped_quotes_from_real_claude_output
    mock_output = "Perfect! I've loaded the task information. Let me parse and display the details:\n\n## Task Information\n\n**Task Name:** (ActionDispatch::MissingController) \"uninitialized constant Api::OfficesController\"\n\n```json\nTASKRUNNER_RESULT: {\\\"status\\\": \\\"success\\\", \\\"task_info\\\": {\\\"name\\\": \\\"(ActionDispatch::MissingController) \\\\\\\"uninitialized constant Api::OfficesController\\\\\\\"\\\", \\\"id\\\": 9005, \\\"description\\\": \\\"Test description\\\", \\\"status\\\": \\\"Nove\\\", \\\"priority\\\": \\\"Urgentni\\\", \\\"assigned_user\\\": \\\"Karel Mracek\\\", \\\"scrum_points\\\": \\\"Mirne obtizne\\\"}, \\\"hours\\\": {\\\"per_day\\\": 8, \\\"task_estimated\\\": 1.0}}\n```"

    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:parse_result, mock_output, 0.25)

    assert_equal 'success', result['status'], 'Should parse JSON with escaped quotes successfully'
    assert_equal 9005, result['task_info']['id']
    assert_equal 'Karel Mracek', result['task_info']['assigned_user']
    assert_equal 8, result['hours']['per_day']
    assert_equal 1.0, result['hours']['task_estimated']
    assert_equal 0.25, result['hours']['task_worked']
  end

  def test_parse_result_with_stream_json_wrapped_result
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@text_content,
                               'I analyzed the task.\nTASKRUNNER_RESULT: {"status": "success", "task_id": 9508, "recommended_model": "sonnet", "hours": {"per_day": 8}}')

    result = base.send(:parse_result, 'raw stream json that does not contain marker', 1.0)

    assert_equal 'success', result['status']
    assert_equal 9508, result['task_id']
    assert_equal 'sonnet', result['recommended_model']
    assert_equal 1.0, result['hours']['task_worked']
  end

  def test_parse_result_falls_back_to_raw_output_when_text_content_empty
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@text_content, '')

    raw = 'TASKRUNNER_RESULT: {"status": "success", "hours": {"per_day": 4}}'
    result = base.send(:parse_result, raw, 0.5)

    assert_equal 'success', result['status']
    assert_equal 4, result['hours']['per_day']
  end

  def test_parse_result_falls_back_to_raw_when_text_content_lacks_marker
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@text_content, 'Some text without the marker')

    raw = 'TASKRUNNER_RESULT: {"status": "success", "hours": {"per_day": 6}}'
    result = base.send(:parse_result, raw, 0.3)

    assert_equal 'success', result['status']
    assert_equal 6, result['hours']['per_day']
  end

  def test_parse_result_with_json_key_marker
    mock_output = '{"TASKRUNNER_RESULT": true, "status": "success", "hours": {"per_day": 8, "task_estimated": 2}}'
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:parse_result, mock_output, 1.5)

    assert_equal 'success', result['status']
    assert_equal 8, result['hours']['per_day']
    assert_equal 2, result['hours']['task_estimated']
    assert_equal 1.5, result['hours']['task_worked']
    refute result.key?('TASKRUNNER_RESULT'), 'TASKRUNNER_RESULT key should be removed from result'
  end

  def test_parse_result_with_json_key_marker_in_code_block
    mock_output = "Here is the result:\n\n```json\n{\"TASKRUNNER_RESULT\": true, \"status\": \"success\", \"hours\": {\"per_day\": 6}}\n```"
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:parse_result, mock_output, 0.5)

    assert_equal 'success', result['status']
    assert_equal 6, result['hours']['per_day']
  end

  def test_parse_result_with_json_key_marker_in_text_content
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@text_content,
                               "Analysis done.\n{\"TASKRUNNER_RESULT\": true, \"status\": \"success\", \"task_id\": 9843, \"hours\": {\"per_day\": 8}}")

    result = base.send(:parse_result, 'raw stream without marker', 1.0)

    assert_equal 'success', result['status']
    assert_equal 9843, result['task_id']
  end

  def test_parse_result_json_key_falls_back_to_raw_stdout
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_set(:@text_content, 'No marker here')

    raw = '{"TASKRUNNER_RESULT": true, "status": "success", "hours": {"per_day": 4}}'
    result = base.send(:parse_result, raw, 0.3)

    assert_equal 'success', result['status']
    assert_equal 4, result['hours']['per_day']
  end

  def test_extract_text_from_line_with_text_delta_event
    base = McptaskRunner::ClaudeCodeBase.new
    line = '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello world"}}'
    assert_equal 'Hello world', base.send(:extract_text_from_line, line)
  end

  def test_extract_text_from_line_with_assistant_message_event
    base = McptaskRunner::ClaudeCodeBase.new
    line = '{"type":"assistant","message":{"content":[{"type":"text","text":"Full message here"}]}}'
    assert_equal 'Full message here', base.send(:extract_text_from_line, line)
  end

  def test_extract_text_from_line_with_non_text_event
    base = McptaskRunner::ClaudeCodeBase.new
    line = '{"type":"result","cost_usd":0.05}'
    assert_equal '', base.send(:extract_text_from_line, line)
  end

  def test_extract_text_from_line_with_invalid_json
    base = McptaskRunner::ClaudeCodeBase.new
    assert_equal '', base.send(:extract_text_from_line, 'not json')
  end

  def test_extract_text_from_line_with_multiple_content_blocks
    base = McptaskRunner::ClaudeCodeBase.new
    line = '{"type":"assistant","message":{"content":[{"type":"text","text":"Part 1"},{"type":"tool_use","id":"123"},{"type":"text","text":"Part 2"}]}}'
    assert_equal 'Part 1Part 2', base.send(:extract_text_from_line, line)
  end

  def test_write_debug_dump_creates_file
    base = McptaskRunner::ClaudeCodeBase.new
    base.instance_variable_get(:@state).stream_line_count = 198
    base.instance_variable_set(:@text_content, "line 1\nline 2\n")
    base.instance_variable_set(:@log_tag, 'test')

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        base.send(:write_debug_dump, 'some stderr', 99_999)
        dumps = Dir.glob('log/debug_dump_*.txt')
        assert_equal 1, dumps.size
        content = File.read(dumps.first)
        assert_includes content, 'Stream event count: 198'
        assert_includes content, 'ACTIVE TOOL CALLS'
        assert_includes content, 'PROCESS TREE'
        assert_includes content, 'some stderr'
        assert_includes content, 'line 1'
      end
    end
  end

  def test_marker_parse_failed_true_when_marker_absent
    base = McptaskRunner::ClaudeCodeBase.new
    assert base.send(:marker_parse_failed?, { 'status' => 'error', 'message' => 'No TASKRUNNER_RESULT found in output' })
  end

  def test_marker_parse_failed_false_when_status_success
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.send(:marker_parse_failed?, { 'status' => 'success', 'pr_number' => 1158 })
  end

  def test_marker_parse_failed_false_when_claude_reports_legit_error
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.send(:marker_parse_failed?, { 'status' => 'error', 'message' => 'CI failed after fix attempts' })
  end
end
