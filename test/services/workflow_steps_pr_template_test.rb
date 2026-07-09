# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

# Tests that the configurable PR template path is reflected in the workflow
# instructions produced by WorkflowSteps#create_pr_step.
class WorkflowStepsPrTemplateTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('pr_template_steps_test')
    @orig_pwd = Dir.pwd
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@orig_pwd)
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def write_config(pr_template_yaml)
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    indented = pr_template_yaml.each_line.map { |line| "  #{line}" }.join
    File.write(File.join(dir, 'mcptask_runner.yml'), "pr_template:\n#{indented}")
  end

  def instructions
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123).send(:build_instructions)
      end
    end
  end

  def test_default_github_template_path_used_when_no_config
    text = instructions
    assert_includes text, '.github/pull_request_template.md'
  end

  def test_custom_path_replaces_default
    write_config("path: .gitlab/merge_request_templates/Default.md\n")
    text = instructions
    assert_includes text, '.gitlab/merge_request_templates/Default.md'
    refute_includes text, '.github/pull_request_template.md'
  end

  def test_empty_path_in_config_falls_back_to_default
    write_config("path: \"\"\n")
    text = instructions
    assert_includes text, '.github/pull_request_template.md'
  end
end
