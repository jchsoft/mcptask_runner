# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeTriageTest < Minitest::Test
  def test_triage_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::Triage < McptaskRunner::ClaudeCodeBase
  end

  def test_triage_uses_smart_model
    triage = McptaskRunner::ClaudeCode::Triage.new
    assert_equal 'smart', triage.send(:model_name)
  end

  def test_triage_does_not_accept_edits
    triage = McptaskRunner::ClaudeCode::Triage.new
    refute triage.send(:accept_edits?)
  end

  def test_triage_responds_to_run
    triage = McptaskRunner::ClaudeCode::Triage.new
    assert_respond_to triage, :run
  end

  def test_instructions_include_model_selection_rules
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, 'recommended_model'
        assert_includes instructions, 'genius'
        assert_includes instructions, 'smart'
        assert_includes instructions, 'TASKRUNNER_RESULT'
      end
    end
  end

  def test_instructions_use_next_url_without_task_id
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, '@next?project_relative_id=7'
      end
    end
  end

  def test_instructions_use_direct_url_with_task_id
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new(task_id: 456)
        instructions = triage.send(:build_instructions)

        assert_includes instructions, 'mcptask://pieces/jchsoft/456'
        refute_includes instructions, '@next'
      end
    end
  end

  def test_instructions_include_resuming_field
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, 'resuming'
      end
    end
  end

  def test_discovery_triage_disables_branch_resume
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        refute_includes instructions, 'RESUME DETECTION'
        refute_includes instructions, 'gh pr list --head'
        assert_includes instructions, 'NO BRANCH RESUME'
        assert_includes instructions, 'STEP 2'
      end
    end
  end

  def test_pinned_triage_keeps_resume_detection
    triage = McptaskRunner::ClaudeCode::Triage.new(task_id: 456)
    instructions = triage.send(:build_instructions)

    assert_includes instructions, 'RESUME DETECTION'
    assert_includes instructions, 'git branch --show-current'
  end

  def test_instructions_allow_genius_smart_or_primitive
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, 'genius'
        assert_includes instructions, '"primitive": trivial'
      end
    end
  end

  def test_instructions_include_classification_criteria
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, 'Story'
        assert_includes instructions, 'improvements'
        assert_includes instructions, 'CRUD'
        assert_includes instructions, 'refactoring'
        assert_includes instructions, 'attachment'
      end
    end
  end

  def test_instructions_force_genius_on_resume
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        instructions = McptaskRunner::ClaudeCode::Triage.new.send(:build_instructions)

        assert_includes instructions, 'RESUMING OVERRIDE'
        assert_includes instructions, 'resuming=true'
      end
    end
  end

  def test_story_triage_instructions_force_genius_on_resume
    instructions = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965).send(:build_instructions)

    assert_includes instructions, 'RESUMING OVERRIDE'
  end

  def test_instructions_default_to_smart
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, '"smart" (DEFAULT)'
        assert_includes instructions, 'DURATION HINT'
      end
    end
  end

  def test_story_triage_defaults_to_smart
    triage = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965)
    instructions = triage.send(:build_instructions)

    assert_includes instructions, '"smart" (DEFAULT)'
    assert_includes instructions, 'DURATION HINT'
  end

  # Story triage tests

  def test_story_triage_uses_story_instructions
    triage = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965)
    instructions = triage.send(:build_instructions)

    assert_includes instructions, 'LOAD STORY'
    assert_includes instructions, 'mcptask://pieces/jchsoft/8965'
    assert_includes instructions, 'subtask'
    refute_includes instructions, 'RESUME DETECTION'
  end

  def test_story_triage_includes_model_selection_rules
    triage = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965)
    instructions = triage.send(:build_instructions)

    assert_includes instructions, 'recommended_model'
    assert_includes instructions, 'genius'
    assert_includes instructions, 'smart'
    assert_includes instructions, 'TASKRUNNER_RESULT'
  end

  def test_story_triage_does_not_include_branch_detection
    triage = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965)
    instructions = triage.send(:build_instructions)

    refute_includes instructions, 'git branch --show-current'
    refute_includes instructions, 'RESUME DETECTION'
  end

  def test_story_triage_finds_incomplete_subtasks
    triage = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965)
    instructions = triage.send(:build_instructions)

    assert_includes instructions, 'Schváleno'
    assert_includes instructions, 'Hotovo?'
    assert_includes instructions, 'progress<100'
  end

  def test_standard_triage_without_story_id
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        refute_includes instructions, 'LOAD STORY'
        assert_includes instructions, 'NO BRANCH RESUME'
      end
    end
  end

  # Story detection from @next tests

  def test_standard_triage_includes_story_handling_step
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, 'STEP 2b - STORY'
        assert_includes instructions, 'piece_type'
        assert_includes instructions, 'story_id'
      end
    end
  end

  def test_standard_triage_result_format_includes_piece_type_and_story_id
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        assert_includes instructions, '"piece_type": "Task"'
        assert_includes instructions, '"story_id": null'
        assert_includes instructions, 'piece_type: "Task" or "Story"'
      end
    end
  end

  def test_standard_triage_story_step_finds_incomplete_subtasks
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        triage = McptaskRunner::ClaudeCode::Triage.new
        instructions = triage.send(:build_instructions)

        step_2b_pos = instructions.index('STEP 2b')
        assert step_2b_pos, 'Instructions must include STEP 2b for Story handling'
        assert_includes instructions, 'Schváleno'
        assert_includes instructions, 'Hotovo?'
        assert_includes instructions, 'progress<100'
      end
    end
  end

  # Quota is enforced by the runner (QuotaGuard/REST), not the triage agent. The triage prompt
  # must no longer mention quota, read mcptask://user for hours, or emit an hours block.
  def test_triage_prompt_has_no_quota_responsibility
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        instructions = McptaskRunner::ClaudeCode::Triage.new.send(:build_instructions)

        refute_includes instructions, 'DAILY QUOTA'
        refute_includes instructions, 'worked_out'
        refute_includes instructions, 'hour_goal'
        refute_includes instructions, 'already_worked'
      end
    end
  end

  def test_story_triage_prompt_has_no_quota_responsibility
    instructions = McptaskRunner::ClaudeCode::Triage.new(story_id: 99).send(:build_instructions)

    refute_includes instructions, 'DAILY QUOTA'
    refute_includes instructions, 'worked_out'
    refute_includes instructions, 'hour_goal'
  end

  # ReadMcpResourceTool is a DEFERRED tool: its schema is not loaded until ToolSearch pulls it in.
  # A triage child that merely NOTICES the tool is missing gives up and emits status "error" (the
  # prompt's "On MCP failure: STOP" reads a deferred tool as an outage), killing the whole work
  # loop. #38 fixed the execution prompts but wrongly assumed triage was immune — production logs
  # showed triage bailing at STEP 2. Guard the ToolSearch-first hint on every triage fetch.
  def test_discovery_triage_tells_model_to_load_deferred_readmcpresource_tool
    File.stub :exist?, true do
      File.stub :read, 'project_relative_id=7
account_code: `jchsoft`' do
        instructions = McptaskRunner::ClaudeCode::Triage.new.send(:build_instructions)

        assert_includes instructions, 'DEFERRED TOOLS'
        assert_includes instructions, 'select:ReadMcpResourceTool'
      end
    end
  end

  def test_pinned_triage_tells_model_to_load_deferred_readmcpresource_tool
    instructions = McptaskRunner::ClaudeCode::Triage.new(task_id: 456).send(:build_instructions)

    assert_includes instructions, 'DEFERRED TOOLS'
    assert_includes instructions, 'select:ReadMcpResourceTool'
  end

  def test_story_triage_tells_model_to_load_deferred_readmcpresource_tool
    instructions = McptaskRunner::ClaudeCode::Triage.new(story_id: 8965).send(:build_instructions)

    assert_includes instructions, 'DEFERRED TOOLS'
    assert_includes instructions, 'select:ReadMcpResourceTool'
  end
end
