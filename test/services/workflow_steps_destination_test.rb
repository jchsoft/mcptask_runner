# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

# Tests for the auto-bug destination wiring in workflow_steps.rb's
# preexisting_test_errors_instruction. The instruction is the LLM-facing
# fragment that tells the agent how to file an urgent bug when tests are
# failing before its changes. We want it to:
#   - stay clean when no destination is configured (no parent_id line)
#   - mention parent_id when an Epic is configured, so the agent passes it
#     through to CreatePieceTool and the bug lands under the right Epic.
class PreexistingTestErrorsDestinationTest < Minitest::Test
  Klass = McptaskRunner::Concerns::BugDestinationConfig

  def setup
    @tmpdir = Dir.mktmpdir('preex_dest_test')
    @orig_pwd = Dir.pwd
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@orig_pwd)
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def write_destination(yaml)
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    indented = yaml.each_line.map { |line| "  #{line}" }.join
    File.write(File.join(dir, 'mcptask_runner.yml'), "bug_destination:\n#{indented}")
  end

  def with_claude_md(content)
    File.write('CLAUDE.md', content)
  end

  def instructions
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123).send(:build_instructions)
      end
    end
  end

  def test_no_parent_id_line_when_no_destination_configured
    # baseline — no config file
    text = instructions
    assert_includes text, 'PREEXISTING TEST ERRORS'
    refute_match(/parent_id:/, text)
  end

  def test_parent_id_included_when_destination_configured
    write_destination("epic_relative_id: 99999\nepic_name: Auto-bugs\n")

    text = instructions
    assert_includes text, 'PREEXISTING TEST ERRORS'
    assert_match(/parent_id:\s*99999/, text)
  end

  def test_parent_id_line_present_alongside_other_create_piece_fields
    write_destination("epic_relative_id: 11111\n")

    text = instructions
    # The parent_id line should sit inside the same CreatePieceTool call description block
    # as the other CreatePieceTool fields (priority_code, project_id, etc.) so the agent
    # picks it up together with them.
    preex_section = text[/PREEXISTING TEST ERRORS.*?Do NOT fix them.*?$/m]
    refute_nil preex_section
    assert_match(/priority_code/, preex_section)
    assert_match(/project_id/,   preex_section)
    assert_match(/parent_id:\s*11111/, preex_section)
  end

  def test_invalid_destination_config_does_not_inject_parent_id
    write_destination("epic_relative_id: not-a-number\n")

    text = instructions
    refute_match(/parent_id:\s*not-a-number/, text)
  end

  def test_today_auto_squash_also_includes_parent_id
    write_destination("epic_relative_id: 55555\n")

    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        text = McptaskRunner::ClaudeCode::TodayAutoSquash.new.send(:build_instructions)
        assert_match(/parent_id:\s*55555/, text)
      end
    end
  end

  def test_queue_auto_squash_also_includes_parent_id
    write_destination("epic_relative_id: 66666\n")

    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        text = McptaskRunner::ClaudeCode::QueueAutoSquash.new.send(:build_instructions)
        assert_match(/parent_id:\s*66666/, text)
      end
    end
  end

  def test_story_auto_squash_also_includes_parent_id
    write_destination("epic_relative_id: 77777\n")

    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        text = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456).send(:build_instructions)
        assert_match(/parent_id:\s*77777/, text)
      end
    end
  end

  def test_once_auto_squash_also_includes_parent_id
    write_destination("epic_relative_id: 88888\n")

    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        text = McptaskRunner::ClaudeCode::OnceAutoSquash.new.send(:build_instructions)
        assert_match(/parent_id:\s*88888/, text)
      end
    end
  end

  def test_dry_omits_preexisting_section_and_parent_id
    write_destination("epic_relative_id: 88888\n")

    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        text = McptaskRunner::ClaudeCode::Dry.new.send(:build_instructions)
        refute_includes text, 'PREEXISTING TEST ERRORS'
        refute_match(/parent_id:\s*88888/, text)
      end
    end
  end
end
