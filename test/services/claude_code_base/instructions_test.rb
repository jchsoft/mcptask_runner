# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseInstructionsTest < Minitest::Test
  def test_time_awareness_instruction_returns_string
    base = McptaskRunner::ClaudeCodeBase.new
    instruction = base.send(:time_awareness_instruction)
    assert_includes instruction, '>70 min elapsed'
    assert_includes instruction, 'TASKRUNNER_RESULT'
  end

  def test_result_format_instruction_includes_json_code_block
    base = McptaskRunner::ClaudeCodeBase.new
    instruction = base.send(:result_format_instruction, '"status": "success"')

    assert_includes instruction, '```json'
    assert_includes instruction, '"TASKRUNNER_RESULT": true'
    assert_includes instruction, '"status": "success"'
    assert_includes instruction, 'CRITICAL FORMATTING'
  end

  def test_result_format_instruction_with_extra_rules
    base = McptaskRunner::ClaudeCodeBase.new
    instruction = base.send(:result_format_instruction, '"status": "success"',
                            extra_rules: ['task_id MUST be numeric'])

    assert_includes instruction, 'task_id MUST be numeric'
  end

  def test_branch_resume_check_step_no_longer_exists
    base = McptaskRunner::ClaudeCodeBase.new
    refute base.respond_to?(:branch_resume_check_step, true),
           'branch_resume_check_step removed — branch-based task discovery disabled (task #10464)'
  end

  def test_triaged_git_step_resuming_skips_checkout
    base = McptaskRunner::ClaudeCodeBase.new
    step = base.send(:triaged_git_step, resuming: true)
    assert_includes step, 'RESUME'
    refute_includes step, 'git checkout main'
    assert_includes step, 'SKIP steps 2-3'
  end

  def test_triaged_git_step_not_resuming_checks_out_main
    base = McptaskRunner::ClaudeCodeBase.new
    step = base.send(:triaged_git_step, resuming: false)
    assert_includes step, 'git checkout main && git pull'
    refute_includes step, 'RESUME'
  end
end
