# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'

# Tests for the unified mcptask_runner config loader.
#
# The loader resolves FILE_NAME from Dir.pwd at every call, so we chdir into a
# tmpdir that contains the config file (or omits it) — no stubbing required.
class McptaskRunnerConfigTest < Minitest::Test
  Klass = McptaskRunner::Concerns::McptaskRunnerConfig

  def setup
    @tmpdir = Dir.mktmpdir('mcptask_runner_config_test')
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
    File.write(File.join(dir, 'mcptask_runner.yml'), yaml)
  end

  def test_missing_file_returns_empty_hash
    assert_equal({}, Klass.load)
  end

  def test_loads_all_sections
    write_config(<<~YAML)
      models:
        genius: claude-opus-4-8
        smart: claude-sonnet-4-6
        primitive: claude-haiku-4-5-20251001
      launcher:
        command: [ollama, launch, claude]
      bug_destination:
        epic_relative_id: 12345
        epic_name: Auto-bugs
      waiting_strategy:
        short_wait_minutes: 5
        long_wait_minutes: 30
    YAML

    cfg = Klass.load
    assert_equal 'claude-opus-4-8', cfg['models']['genius']
    assert_equal %w[ollama launch claude], cfg['launcher']['command']
    assert_equal 12_345, cfg['bug_destination']['epic_relative_id']
    assert_equal 'Auto-bugs', cfg['bug_destination']['epic_name']
    assert_equal 5, cfg['waiting_strategy']['short_wait_minutes']
    assert_equal 30, cfg['waiting_strategy']['long_wait_minutes']
  end

  def test_loads_only_models
    write_config("models:\n  genius: claude-opus-4-8\n")
    cfg = Klass.load
    assert_equal 'claude-opus-4-8', cfg['models']['genius']
    assert_nil cfg['launcher']
    assert_nil cfg['bug_destination']
    assert_nil cfg['waiting_strategy']
  end

  def test_empty_yaml_returns_empty_hash
    write_config("")
    assert_equal({}, Klass.load)
  end

  def test_malformed_yaml_does_not_raise
    write_config(": : not yaml\n")
    assert_equal({}, Klass.load)
  end

  def test_non_hash_root_returns_empty
    write_config("- just\n- a\n- list\n")
    assert_equal({}, Klass.load)
  end

  def test_exist_returns_true_when_file_present
    write_config("models:\n  genius: opus\n")
    assert Klass.exist?
  end

  def test_exist_returns_false_when_file_missing
    refute Klass.exist?
  end
end
