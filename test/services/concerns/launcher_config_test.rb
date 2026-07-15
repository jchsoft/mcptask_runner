# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

# Unit tests for the launcher config loader.
#
# Like the unified config loader, LauncherConfig resolves the file from Dir.pwd
# on every call, so we chdir into a tmpdir holding (or omitting) the config —
# no stubbing required.
class LauncherConfigTest < Minitest::Test
  Klass = McptaskRunner::Concerns::LauncherConfig

  def setup
    @tmpdir = Dir.mktmpdir('launcher_config_test')
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

  def test_defaults_when_no_config
    assert_nil Klass.command
    assert_equal Klass::DEFAULT_FLAGS, Klass.flags
    refute Klass.flags_overridden?
  end

  def test_command_prefix_from_config
    write_config(<<~YAML)
      launcher:
        command: [codex, exec]
    YAML

    assert_equal %w[codex exec], Klass.command
  end

  def test_flags_merge_over_defaults
    write_config(<<~YAML)
      launcher:
        command: [aider]
        flags:
          prompt: "--message"
          model: "--model"
    YAML

    flags = Klass.flags
    assert_equal '--message', flags['prompt'], 'overridden prompt flag'
    assert_equal '--model', flags['model']
    assert_equal '--verbose', flags['verbose'], 'untouched key keeps the claude default'
    assert Klass.flags_overridden?
  end

  def test_null_flag_survives_merge_as_nil
    write_config(<<~YAML)
      launcher:
        flags:
          output_format: null
          verbose: null
          disallowed_tools: null
    YAML

    flags = Klass.flags
    assert_nil flags['output_format'], 'null in config means omit the flag'
    assert_nil flags['verbose']
    assert_nil flags['disallowed_tools']
  end

  def test_malformed_config_falls_back_to_defaults
    write_config("launcher: : : not valid yaml\n\t- broken")

    assert_nil Klass.command
    assert_equal Klass::DEFAULT_FLAGS, Klass.flags
  end
end
