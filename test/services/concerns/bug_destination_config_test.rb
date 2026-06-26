# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'

# Tests for the per-host bug-destination config loader.
#
# The loader resolves FILE_PATH from Dir.pwd at first read, so we simply
# chdir into a tmpdir that contains the config file — no stubbing required.
class BugDestinationConfigTest < Minitest::Test
  Klass = McptaskRunner::Concerns::BugDestinationConfig

  def setup
    @tmpdir = Dir.mktmpdir('bug_dest_config_test')
    @orig_pwd = Dir.pwd
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@orig_pwd)
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def write_config(yaml)
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'bug_destination.yml'), yaml)
  end

  def test_missing_file_returns_nil_values
    cfg = Klass.load
    assert_nil cfg[:epic_relative_id]
    assert_nil cfg[:epic_name]
  end

  def test_loads_integer_relative_id
    write_config("epic_relative_id: 12345\n")
    cfg = Klass.load
    assert_equal 12_345, cfg[:epic_relative_id]
  end

  def test_loads_string_numeric_relative_id
    write_config("epic_relative_id: '67890'\n")
    cfg = Klass.load
    assert_equal 67_890, cfg[:epic_relative_id]
  end

  def test_invalid_relative_id_returns_nil
    write_config("epic_relative_id: not-a-number\n")
    cfg = Klass.load
    assert_nil cfg[:epic_relative_id]
  end

  def test_loads_epic_name
    write_config("epic_relative_id: 12345\nepic_name: Auto-bugs\n")
    cfg = Klass.load
    assert_equal 12_345, cfg[:epic_relative_id]
    assert_equal 'Auto-bugs', cfg[:epic_name]
  end

  def test_empty_epic_name_becomes_nil
    write_config("epic_relative_id: 12345\nepic_name: \"  \"\n")
    cfg = Klass.load
    assert_nil cfg[:epic_name]
  end

  def test_malformed_yaml_does_not_raise
    write_config(": : not yaml\n")
    cfg = Klass.load
    assert_nil cfg[:epic_relative_id]
    assert_nil cfg[:epic_name]
  end

  def test_describe_shows_epic_when_configured
    write_config("epic_relative_id: 12345\nepic_name: Auto-bugs\n")
    assert_equal 'Bug destination: Epic #12345 (Auto-bugs)', Klass.describe
  end

  def test_describe_omits_label_when_no_name
    write_config("epic_relative_id: 99\n")
    assert_equal 'Bug destination: Epic #99', Klass.describe
  end

  def test_describe_shows_project_root_when_missing
    assert_equal 'Bug destination: project root (no config/bug_destination.yml)', Klass.describe
  end
end
