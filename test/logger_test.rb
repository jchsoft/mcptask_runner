require 'test_helper'
require 'stringio'

class LoggerTest < Minitest::Test
  def setup
    @log_output = StringIO.new
    @custom_logger = ::Logger.new(@log_output)
    McptaskRunner::Logger.logger = @custom_logger
  end

  def teardown
    McptaskRunner::Logger.logger = nil
  end

  def test_info_stdout_outputs_to_both_stdout_and_log
    assert_output("Test message\n") do
      McptaskRunner::Logger.info_stdout('Test message')
    end
    assert_includes @log_output.string, 'Test message'
    assert_includes @log_output.string, 'INFO'
  end

  def test_debug_only_goes_to_log
    assert_output('') do
      McptaskRunner::Logger.debug('Debug message')
    end
    assert_includes @log_output.string, 'Debug message'
    assert_includes @log_output.string, 'DEBUG'
  end

  def test_info_only_goes_to_log
    assert_output('') do
      McptaskRunner::Logger.info('Info message')
    end
    assert_includes @log_output.string, 'Info message'
    assert_includes @log_output.string, 'INFO'
  end

  def test_warn_outputs_to_both_with_emoji
    assert_output(/⚠️  Warning message/) do
      McptaskRunner::Logger.warn('Warning message')
    end
    assert_includes @log_output.string, 'Warning message'
    assert_includes @log_output.string, 'WARN'
  end

  def test_error_outputs_to_both_with_emoji
    assert_output(/❌ Error message/) do
      McptaskRunner::Logger.error('Error message')
    end
    assert_includes @log_output.string, 'Error message'
    assert_includes @log_output.string, 'ERROR'
  end

  def test_logger_creates_log_directory_and_file
    # Clean up first
    FileUtils.rm_rf('log') if Dir.exist?('log')

    # Create default logger (should create log directory and timestamped file)
    McptaskRunner::Logger.logger = nil
    McptaskRunner::Logger.logger

    assert Dir.exist?('log'), 'log directory should be created'
    assert McptaskRunner::Logger.run_log_path, 'run_log_path should be set after logger init'
    assert File.exist?(McptaskRunner::Logger.run_log_path), 'timestamped log file should be created'
    assert_match(/mcptask_runner_\d{8}_\d{6}\.log\z/, McptaskRunner::Logger.run_log_path)

    # Clean up
    FileUtils.rm_rf('log') if Dir.exist?('log')
  end

  def test_run_log_path_cleared_on_logger_reset
    McptaskRunner::Logger.logger = nil
    McptaskRunner::Logger.logger
    assert McptaskRunner::Logger.run_log_path

    McptaskRunner::Logger.logger = nil
    assert_nil McptaskRunner::Logger.run_log_path
  end

  def test_latest_run_log_returns_most_recent_file
    dir = 'log'
    FileUtils.mkdir_p(dir)
    older = File.join(dir, 'mcptask_runner_20260101_080000.log')
    newer = File.join(dir, 'mcptask_runner_20260601_120000.log')
    File.write(older, 'old')
    File.write(newer, 'new')

    assert_equal newer, McptaskRunner::Logger.latest_run_log
  ensure
    File.delete(older) if File.exist?(older)
    File.delete(newer) if File.exist?(newer)
  end

  def test_multiple_messages_accumulate_in_log
    3.times { |i| McptaskRunner::Logger.debug("Message #{i}") }
    log_content = @log_output.string
    assert_includes log_content, 'Message 0'
    assert_includes log_content, 'Message 1'
    assert_includes log_content, 'Message 2'
  end
end
