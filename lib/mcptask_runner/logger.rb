require 'logger'
require 'fileutils'

module McptaskRunner
  module Logger
    class << self
      def logger=(val)
        @run_log_path = nil
        @logger = val
      end

      def logger
        @logger ||= create_default_logger
      end

      # Path to the log file created by this process's run. Nil until logger initializes.
      def run_log_path
        @run_log_path
      end

      # Most recent per-run log file on disk (by filename lexicographic order).
      # Does not trigger logger initialization.
      def latest_run_log
        Dir.glob(File.join('log', 'mcptask_runner_[0-9]*.log')).max
      end

      # Output to both stdout and log file (for user-facing messages)
      def info_stdout(message)
        puts message
        logger.info(message)
      end

      # Output to log file only (for debug/internal messages)
      def debug(message)
        logger.debug(message)
      end

      def info(message)
        logger.info(message)
      end

      def warn(message)
        puts "⚠️  #{message}"
        logger.warn(message)
      end

      def error(message)
        puts "❌ #{message}"
        logger.error(message)
      end

      private

      def create_default_logger
        log_dir = 'log'
        FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)

        timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
        @run_log_path = File.join(log_dir, "mcptask_runner_#{timestamp}.log")
        file_logger = ::Logger.new(@run_log_path)
        file_logger.level = ::Logger::DEBUG
        file_logger.formatter = proc do |severity, datetime, progname, msg|
          "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity.ljust(5)} - #{msg}\n"
        end
        file_logger
      end
    end
  end
end
