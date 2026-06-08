# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class ClaudeMdTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('claude_md_test')
    @prev_dir = Dir.pwd
    Dir.chdir(@tmpdir)
    McptaskRunner::ClaudeMd.reset_cache!
  end

  def teardown
    McptaskRunner::ClaudeMd.reset_cache!
    Dir.chdir(@prev_dir) if @prev_dir
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  # ---- format variations ----

  def test_standard_bullet_with_quotes
    write_claude_md("- Project name is: \"McpTask rails runner\"")
    assert_equal 'McpTask rails runner', McptaskRunner::ClaudeMd.project_name
  end

  def test_bullet_without_quotes
    write_claude_md("- Project name is: McpTask rails runner")
    assert_equal 'McpTask rails runner', McptaskRunner::ClaudeMd.project_name
  end

  def test_no_leading_dash
    write_claude_md("Project name is: \"mcptask.online\"")
    assert_equal 'mcptask.online', McptaskRunner::ClaudeMd.project_name
  end

  def test_asterisk_bullet
    write_claude_md("* Project name is: \"Foo Bar\"")
    assert_equal 'Foo Bar', McptaskRunner::ClaudeMd.project_name
  end

  def test_case_insensitive_keyword
    write_claude_md("- PROJECT NAME IS: \"Mixed Case\"")
    assert_equal 'Mixed Case', McptaskRunner::ClaudeMd.project_name
  end

  def test_strips_trailing_paren_reference
    write_claude_md("- Project name is: \"McpTask rails runner\" (69)")
    assert_equal 'McpTask rails runner', McptaskRunner::ClaudeMd.project_name
  end

  def test_keyword_not_at_start_of_line_is_ignored
    write_claude_md("Some other content\n- Project name is: \"Real One\"\nMore text")
    assert_equal 'Real One', McptaskRunner::ClaudeMd.project_name
  end

  # ---- missing / unreadable CLAUDE.md ----

  def test_missing_claude_md_falls_back_to_basename
    refute File.exist?('CLAUDE.md')
    assert_equal File.basename(Dir.pwd), McptaskRunner::ClaudeMd.project_name
  end

  def test_claude_md_with_no_match_falls_back_to_basename
    write_claude_md("# My Project\n\nNo name line here.\n")
    assert_equal File.basename(Dir.pwd), McptaskRunner::ClaudeMd.project_name
  end

  # ---- robustness ----

  def test_returns_string_never_nil
    write_claude_md('')
    result = McptaskRunner::ClaudeMd.project_name
    assert_kind_of String, result
    refute_empty result
  end

  def test_rescues_read_errors
    File.stub :exist?, true do
      File.stub :read, ->(*) { raise Errno::EACCES, 'denied' } do
        assert_equal File.basename(Dir.pwd), McptaskRunner::ClaudeMd.project_name
      end
    end
  end

  # ---- memoization ----

  def test_result_is_memoized
    write_claude_md("- Project name is: \"First\"")
    assert_equal 'First', McptaskRunner::ClaudeMd.project_name

    # Overwrite file — cached value must NOT change
    write_claude_md("- Project name is: \"Second\"")
    assert_equal 'First', McptaskRunner::ClaudeMd.project_name
  end

  def test_reset_cache_forces_re_read
    write_claude_md("- Project name is: \"First\"")
    assert_equal 'First', McptaskRunner::ClaudeMd.project_name

    write_claude_md("- Project name is: \"Second\"")
    McptaskRunner::ClaudeMd.reset_cache!
    assert_equal 'Second', McptaskRunner::ClaudeMd.project_name
  end

  private

  def write_claude_md(content)
    File.write(File.join(@tmpdir, 'CLAUDE.md'), content)
  end
end
