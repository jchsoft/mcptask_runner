# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'

# Tests for the per-host PR template path config loader.
#
# The loader resolves config/mcptask_runner.yml relative to Dir.pwd, so we
# chdir into a tmpdir — no stubbing required.
class PrTemplateConfigTest < Minitest::Test
  Klass = McptaskRunner::Concerns::PrTemplateConfig

  def setup
    @tmpdir = Dir.mktmpdir('pr_template_config_test')
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

  def test_missing_file_returns_default_path
    cfg = Klass.load
    assert_equal '.github/pull_request_template.md', cfg[:path]
  end

  def test_loads_custom_path
    write_config("path: .gitlab/merge_request_templates/Default.md\n")
    cfg = Klass.load
    assert_equal '.gitlab/merge_request_templates/Default.md', cfg[:path]
  end

  def test_empty_path_falls_back_to_default
    write_config("path: \"\"\n")
    cfg = Klass.load
    assert_equal '.github/pull_request_template.md', cfg[:path]
  end

  def test_whitespace_only_path_falls_back_to_default
    write_config("path: \"   \"\n")
    cfg = Klass.load
    assert_equal '.github/pull_request_template.md', cfg[:path]
  end

  def test_missing_pr_template_section_returns_default
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'mcptask_runner.yml'), "bug_destination:\n  epic_relative_id: 1\n")
    cfg = Klass.load
    assert_equal '.github/pull_request_template.md', cfg[:path]
  end

  def test_malformed_yaml_does_not_raise
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'mcptask_runner.yml'), ": : not yaml\n")
    cfg = Klass.load
    assert_equal '.github/pull_request_template.md', cfg[:path]
  end

  def test_defaults_returns_default_path
    assert_equal '.github/pull_request_template.md', Klass.defaults[:path]
  end
end
