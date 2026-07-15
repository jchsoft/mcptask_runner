require 'time'
require 'fileutils'

module McptaskRunner
  # Standalone stdin->file filter piped from the generated LaunchAgent launcher script
  # (see Services::Installer#launcher_script_body). Splits the raw Claude/EventStream/launcher
  # stdout stream into daily per-project log files and timestamps only the lines that start a
  # logical entry (e.g. "[Claude] ...", "[EventStream] ..."), leaving multi-line JSON bodies
  # untouched so the log stays readable.
  #
  # Invoked as: ruby log_filter.rb <log_base_dir> <slug>
  # Writes to:  <log_base_dir>/<slug>/YYYY-MM-DD.log
  module LogFilter
    module_function

    # Timestamps only lines that begin a new entry (start with "[" at column 0, e.g. "[Claude]",
    # "[EventStream]"). Pretty-printed JSON body lines are always indented, including nested
    # arrays (e.g. "    ["), so checking the raw line (not `lstrip`ped) keeps those unchanged.
    def decorate(line, now)
      return line unless line.start_with?('[')

      "[#{now.strftime('%H:%M:%S')}] #{line}"
    end

    def dated_path(base_dir, slug, now)
      File.join(base_dir, slug, "#{now.strftime('%Y-%m-%d')}.log")
    end

    def run(base_dir, slug, input: $stdin, clock: Time)
      current_path = nil
      file = nil

      input.each_line do |line|
        now = clock.now
        path = dated_path(base_dir, slug, now)

        if path != current_path
          file&.close
          FileUtils.mkdir_p(File.dirname(path))
          file = File.open(path, 'a')
          file.sync = true
          current_path = path
        end

        file.write(decorate(line, now))
      end
    ensure
      file&.close
    end
  end
end

McptaskRunner::LogFilter.run(ARGV[0], ARGV[1]) if __FILE__ == $PROGRAM_NAME
