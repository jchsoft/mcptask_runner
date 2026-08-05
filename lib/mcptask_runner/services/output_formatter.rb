# frozen_string_literal: true

require 'json'
require_relative 'approval_collector'

module McptaskRunner
  # Formats Claude output for better readability
  class OutputFormatter
    @@verbose_mode = false
    @@ascii_mode = nil # nil = auto-detect, true = force ASCII, false = force emoji

    def self.verbose_mode=(value)
      @@verbose_mode = value
    end

    def self.verbose_mode
      @@verbose_mode
    end

    def self.ascii_mode=(value)
      @@ascii_mode = value
    end

    def self.ascii_mode
      @@ascii_mode
    end

    # Use ASCII fallback only when explicitly requested via MCPTASK_RUNNER_ASCII=1
    def self.use_ascii?
      return @@ascii_mode unless @@ascii_mode.nil?

      ENV['MCPTASK_RUNNER_ASCII'] == '1' || ENV['MCPTASK_RUNNER_ASCII'] == 'true'
    end

    # Status icons (emoji by default, ASCII fallback available via MCPTASK_RUNNER_ASCII=1)
    ICONS = {
      completed: { emoji: '✅', ascii: '[x]' },
      in_progress: { emoji: '🔄', ascii: '[>]' },
      pending: { emoji: '⏳', ascii: '[ ]' },
      thinking: { emoji: '💭', ascii: '[.]' },
      task: { emoji: '📋', ascii: '[TASK]' }
    }.freeze

    # ANSI escape codes for terminal formatting
    ANSI = {
      bold: "\e[1m",
      reset: "\e[0m"
    }.freeze

    def self.icon(name)
      icon_set = ICONS[name]
      return '' unless icon_set

      use_ascii? ? icon_set[:ascii] : icon_set[:emoji]
    end

    def self.format_line(line)
      formatted = verbose_mode ? process_line(line) : process_line_normal(line)
      # Strip system-reminder tags from ALL output (covers verbose mode, fallbacks, etc.)
      formatted = strip_system_reminders(formatted)
      # Add blank line before [Claude] prefix, return unfrozen string
      "\n[Claude] #{formatted}".dup
    end

    def self.should_log_to_stdout?(line)
      return true if verbose_mode  # In verbose mode, show everything

      return false unless json_like?(line)

      begin
        parsed = JSON.parse(line)

        # Hide system initialization messages
        return false if parsed['type'] == 'system' && parsed['subtype'] == 'init'

        # Hide result metadata (success/failure tracking)
        return false if parsed['type'] == 'result'

        # Hide session/uuid/metadata-only messages
        return false if parsed.key?('type') && parsed.keys.length < 5 && !parsed.dig('message', 'content')

        # Show messages with actual content
        return true if parsed.dig('message', 'content')

        # Show text content
        return true if parsed['type'] == 'text'

        # Everything else (including Claude's actual work output)
        true
      rescue JSON::ParserError
        true  # If we can't parse, show it (probably important)
      end
    end

    # Verbose mode: output entire JSON as before
    def self.process_line(line)
      if json_like?(line)
        format_json(line)
      else
        process_newlines(line)
      end
    end

    # Normal mode: filter and extract relevant content
    def self.process_line_normal(line)
      if json_like?(line)
        extract_message_content(line)
      else
        process_newlines(line)
      end
    end

    def self.extract_message_content(json_string)
      parsed = JSON.parse(json_string)
      # Navigate to message.content if it exists
      return format_json(json_string) unless parsed.dig('message', 'content')

      content_items = parsed['message']['content']
      return format_json(json_string) unless content_items.is_a?(Array)

      format_content_items(content_items)
    rescue JSON::ParserError
      unescaped = unescape_json(json_string)
      begin
        parsed = JSON.parse(unescaped)
        return format_json(json_string) unless parsed.dig('message', 'content')

        content_items = parsed['message']['content']
        return format_json(json_string) unless content_items.is_a?(Array)

        format_content_items(content_items)
      rescue JSON::ParserError
        process_newlines(json_string)
      end
    end

    def self.format_content_items(items)
      formatted_parts = items.flat_map do |item|
        case item['type']
        when 'text'
          format_text_content(item)
        when 'tool_use'
          format_tool_use_content(item)
        when 'tool_result'
          format_tool_result_content(item)
        when 'thinking'
          format_thinking_content(item)
        else
          "#{item['type']}: #{item.inspect}"
        end
      end

      formatted_parts.join("\n\n")
    end

    def self.format_text_content(item)
      text = item['text'].to_s
      # Replace literal \n with actual newlines
      text = text.gsub('\\n', "\n")

      # Detect and format task info block
      if text.include?('TASKRUNNER_TASK_INFO:')
        formatted = format_task_info_block(text)
        return formatted if formatted
      end

      # Remove system-reminder tags and their content (not meant for user display)
      strip_system_reminders(text)
    end

    def self.strip_system_reminders(text)
      text.gsub(%r{<system-reminder>.*?</system-reminder>}m, '').strip
    end

    def self.format_tool_use_content(item)
      name = item['name'].to_s
      tool_id = item['id'].to_s

      input_text = if name == 'TodoWrite' && item.dig('input', 'todos').is_a?(Array)
                     format_todo_write_input(item['input']['todos'])
      elsif item['input'].is_a?(Hash)
                     JSON.pretty_generate(item['input'])
      else
                     item['input'].inspect
      end

      "Tool: #{name} (ID: #{tool_id})\nInput:\n#{input_text}"
    end

    def self.format_todo_write_input(todos)
      todos.map do |todo|
        status_icon = case todo['status']
                      when 'completed' then icon(:completed)
                      when 'in_progress' then icon(:in_progress)
                      else icon(:pending)
        end
        "#{status_icon} #{todo['content']}"
      end.join("\n")
    end

    def self.format_tool_result_content(item)
      is_error = item['is_error'] ? 'ERROR' : 'OK'
      result_type = item['type'].to_s
      content = strip_system_reminders(item['content'].to_s)

      # Collect commands that require approval for summary at end of session
      ApprovalCollector.extract_from_error(content) if item['is_error']

      "Tool Result (#{is_error}) [#{result_type}]:\n#{content}"
    end

    def self.format_thinking_content(item)
      thinking_text = item['thinking'].to_s
      "thinking: #{icon(:thinking)} \"#{thinking_text}\""
    end

    def self.json_like?(line)
      line.strip.start_with?('{') && line.strip.end_with?('}')
    end

    def self.format_json(json_string)
      parsed = JSON.parse(json_string)
      # Pretty print with 2-space indentation
      JSON.pretty_generate(parsed)
    rescue JSON::ParserError
      # If parsing fails, try to handle escaped JSON
      unescaped = unescape_json(json_string)
      begin
        parsed = JSON.parse(unescaped)
        JSON.pretty_generate(parsed)
      rescue JSON::ParserError
        # If still fails, return original with newline processing
        process_newlines(json_string)
      end
    end

    def self.unescape_json(json_string)
      # Handle multiple levels of backslash escaping
      result = json_string
      result = result.gsub(/\\\\/, '\\') while result.include?('\\\\')
      loop do
        next_result = result.gsub(/\\(["\\])/, '\1')
        break if next_result == result

        result = next_result
      end
      result
    end

    def self.process_newlines(text)
      # Convert literal \n to actual newlines for better readability
      text.gsub('\\n', "\n")
    end

    # Task info block formatting
    def self.format_task_info_block(text)
      return nil unless text.include?('TASKRUNNER_TASK_INFO:')

      # Extract data from the marker format
      id = text[/ID:\s*(.+)/, 1]&.strip
      title = text[/TITLE:\s*(.+)/, 1]&.strip
      desc_match = text.match(/DESCRIPTION:\s*(.+?)(?=END_TASK_INFO|\z)/m)
      description = desc_match ? desc_match[1].strip : nil

      return nil unless id && title

      render_task_box(id, title, description)
    end

    def self.render_task_box(id, title, description)
      width = 80
      double_line = use_ascii? ? '=' * width : '═' * width
      single_line = use_ascii? ? '-' * width : '─' * width
      task_icon = icon(:task)

      truncated_desc = truncate_description(description, 200)

      lines = []
      lines << double_line
      lines << "#{bold}#{task_icon} TASK ##{id}: #{title}#{reset}"
      lines << single_line
      lines << truncated_desc if truncated_desc && !truncated_desc.empty?
      lines << double_line
      lines.join("\n")
    end

    def self.truncate_description(text, max_length)
      return nil if text.nil? || text.empty?

      # Process newlines first
      processed = text.gsub('\\n', "\n").strip
      return processed if processed.length <= max_length

      "#{processed[0, max_length - 3]}..."
    end

    def self.bold
      use_ascii? ? '' : ANSI[:bold]
    end

    def self.reset
      use_ascii? ? '' : ANSI[:reset]
    end
  end
end
