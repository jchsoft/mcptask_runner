# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'

# Tests for the per-host WaitingStrategy duration config loader.
#
# The loader resolves FILE_NAME from Dir.pwd at every call, so we chdir into a
# tmpdir that contains the config file (or omits it) — no stubbing required.
class WaitingStrategyConfigTest < Minitest::Test
  Klass = McptaskRunner::Concerns::WaitingStrategyConfig

  def setup
    @tmpdir = Dir.mktmpdir('waiting_strategy_config_test')
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
    File.write(File.join(dir, 'waiting_strategy.yml'), yaml)
  end

  def test_missing_file_returns_defaults
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
    assert_equal 60, cfg[:long_wait_minutes]
  end

  def test_loads_overrides
    write_config("short_wait_minutes: 5\nlong_wait_minutes: 15\n")
    cfg = Klass.load
    assert_equal 5, cfg[:short_wait_minutes]
    assert_equal 15, cfg[:long_wait_minutes]
  end

  def test_loads_only_short_wait
    write_config("short_wait_minutes: 10\n")
    cfg = Klass.load
    assert_equal 10, cfg[:short_wait_minutes]
    # long_wait falls back to the default
    assert_equal 60, cfg[:long_wait_minutes]
  end

  def test_loads_only_long_wait
    write_config("long_wait_minutes: 45\n")
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
    assert_equal 45, cfg[:long_wait_minutes]
  end

  def test_zero_minutes_falls_back_to_default
    write_config("short_wait_minutes: 0\nlong_wait_minutes: 0\n")
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
    assert_equal 60, cfg[:long_wait_minutes]
  end

  def test_negative_minutes_falls_back_to_default
    write_config("short_wait_minutes: -5\n")
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
  end

  def test_non_numeric_value_falls_back_to_default
    write_config("short_wait_minutes: not-a-number\nlong_wait_minutes: hello\n")
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
    assert_equal 60, cfg[:long_wait_minutes]
  end

  def test_string_numeric_value_is_coerced
    write_config("short_wait_minutes: '7'\nlong_wait_minutes: '42'\n")
    cfg = Klass.load
    assert_equal 7, cfg[:short_wait_minutes]
    assert_equal 42, cfg[:long_wait_minutes]
  end

  def test_float_value_is_coerced_to_integer
    write_config("short_wait_minutes: 3.5\n")
    cfg = Klass.load
    assert_equal 3, cfg[:short_wait_minutes]
  end

  def test_malformed_yaml_does_not_raise
    write_config(": : not yaml\n")
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
    assert_equal 60, cfg[:long_wait_minutes]
  end

  def test_empty_yaml_returns_defaults
    write_config("")
    cfg = Klass.load
    assert_equal 30, cfg[:short_wait_minutes]
    assert_equal 60, cfg[:long_wait_minutes]
  end

  def test_describe_includes_both_durations
    write_config("short_wait_minutes: 5\nlong_wait_minutes: 30\n")
    desc = Klass.describe
    assert_match(/short_wait=5m/, desc)
    assert_match(/long_wait=30m/, desc)
  end

  def test_describe_shows_defaults_when_no_file
    desc = Klass.describe
    assert_match(/short_wait=30m/, desc)
    assert_match(/long_wait=60m/, desc)
  end

  # --- unified config/mcptask_runner.yml path ---

  def write_unified_config(yaml)
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'mcptask_runner.yml'), yaml)
  end

  def test_unified_config_overrides_defaults
    write_unified_config("waiting_strategy:\n  short_wait_minutes: 5\n  long_wait_minutes: 15\n")
    cfg = Klass.load
    assert_equal 5, cfg[:short_wait_minutes]
    assert_equal 15, cfg[:long_wait_minutes]
  end

  def test_unified_config_wins_over_legacy_file
    write_unified_config("waiting_strategy:\n  short_wait_minutes: 5\n")
    write_config("short_wait_minutes: 99\n")
    cfg = Klass.load
    assert_equal 5, cfg[:short_wait_minutes], 'unified config must take precedence over legacy file'
  end

  def test_legacy_file_used_when_unified_config_lacks_waiting_strategy
    write_config("short_wait_minutes: 7\nlong_wait_minutes: 42\n")
    cfg = Klass.load
    assert_equal 7, cfg[:short_wait_minutes]
    assert_equal 42, cfg[:long_wait_minutes]
  end
end
