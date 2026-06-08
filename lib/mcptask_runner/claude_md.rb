# frozen_string_literal: true

module McptaskRunner
  # Resolves metadata (project_name, account_code, project_relative_id, ...)
  # from the project's CLAUDE.md. Centralizes parsing that was previously
  # duplicated and silently returned nil on format drift.
  #
  # All resolvers are class-level, memoized after the first call, and
  # guaranteed to return a String (never nil) — the runner snapshot
  # schema requires project_name, and a silent nil in the web UI's
  # multi-project dashboard was the user-reported bug, task 10590.
  module ClaudeMd
    PROJECT_NAME_REGEX = %r{
      (?:^|\n)                            # start of file or line
      \s*[-*]?                            # optional bullet, dash or asterisk
      \s*Project\s+name(?:\s+is)?:?\s*    # "Project name is:" or "Project name:" keyword
      "?                                  # optional opening quote
      ([^"\n]+?)                          # captured name, non-greedy, no quotes or newlines
      "?                                  # optional closing quote
      \s*                                 # optional whitespace
      (?:\([^)]*\))?                      # optional trailing parenthesized reference
      \s*(?:\n|$)                         # end of line or file
    }xi

    class << self
      def project_name
        @project_name ||= resolve_project_name
      end

      def reset_cache!
        @project_name = nil
      end

      private

      def resolve_project_name
        parsed = read_project_name_from_file
        return parsed if parsed && !parsed.empty?

        basename = File.basename(Dir.pwd)
        return basename unless basename.empty?

        'unknown'
      end

      def read_project_name_from_file
        return nil unless File.exist?('CLAUDE.md')

        match = File.read('CLAUDE.md').match(PROJECT_NAME_REGEX)
        return nil unless match

        match[1].strip
      rescue StandardError
        nil
      end
    end
  end
end
