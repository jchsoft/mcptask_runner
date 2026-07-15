# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'mcptask_runner/log_filter'

class LogFilterTest < Minitest::Test
  Klass = McptaskRunner::LogFilter

  def setup
    @tmpdir = Dir.mktmpdir('log_filter_test')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  # --- decorate ---

  def test_decorate_timestamps_entry_start_lines
    now = Time.new(2026, 7, 15, 8, 30, 5)
    assert_equal "[08:30:05] [EventStream] ready\n", Klass.decorate("[EventStream] ready\n", now)
  end

  def test_decorate_leaves_json_body_lines_unchanged
    now = Time.new(2026, 7, 15, 8, 30, 5)
    assert_equal "  \"a\": 1\n", Klass.decorate("  \"a\": 1\n", now)
  end

  def test_decorate_leaves_blank_lines_unchanged
    now = Time.new(2026, 7, 15, 8, 30, 5)
    assert_equal "\n", Klass.decorate("\n", now)
  end

  def test_decorate_leaves_indented_json_array_lines_unchanged
    now = Time.new(2026, 7, 15, 8, 30, 5)
    # Pretty-printed JSON can nest a bare array element, producing an indented "[" line —
    # this must not be mistaken for an entry-start line like "[Claude]".
    assert_equal "    [\n", Klass.decorate("    [\n", now)
  end

  # --- dated_path ---

  def test_dated_path_builds_per_slug_daily_path
    now = Time.new(2026, 7, 15, 8, 30, 5)
    expected = File.join(@tmpdir, 'my-slug', '2026-07-15.log')
    assert_equal expected, Klass.dated_path(@tmpdir, 'my-slug', now)
  end

  # --- run ---

  def test_run_timestamps_entries_and_rotates_at_midnight
    input = StringIO.new(<<~TEXT)
      [Claude] {
        "a": 1
      }
      [EventStream] ready
    TEXT

    times = [
      Time.new(2026, 7, 15, 23, 59, 59),
      Time.new(2026, 7, 15, 23, 59, 59),
      Time.new(2026, 7, 15, 23, 59, 59),
      Time.new(2026, 7, 16, 0, 0, 1)
    ]
    clock = Class.new { define_method(:now) { times.shift } }.new

    Klass.run(@tmpdir, 'my-slug', input: input, clock: clock)

    day1 = File.read(File.join(@tmpdir, 'my-slug', '2026-07-15.log'))
    day2 = File.read(File.join(@tmpdir, 'my-slug', '2026-07-16.log'))

    assert_equal "[23:59:59] [Claude] {\n  \"a\": 1\n}\n", day1
    assert_equal "[00:00:01] [EventStream] ready\n", day2
  end
end
