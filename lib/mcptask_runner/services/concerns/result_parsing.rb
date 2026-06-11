# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Parses TASKRUNNER_RESULT marker from Claude output (JSON key format and legacy prefix format)
    module ResultParsing
      # Tracks which text source is being searched for the result marker
      ParseSource = Struct.new(:text, :from_text_content, keyword_init: true)

      private

      def parse_result(stdout, elapsed_hours)
        Logger.debug "[#{@log_tag}] [parse_result] Starting to parse Claude output..."

        # Prefer clean extracted text over raw stream-json
        text = @text_content && !@text_content.empty? ? @text_content : stdout
        source = ParseSource.new(text: text, from_text_content: text.equal?(@text_content))
        Logger.debug "[#{@log_tag}] [parse_result] Using #{source.from_text_content ? 'extracted text' : 'raw stream-json'} (#{source.text.length} chars)"

        # Find TASKRUNNER_RESULT marker - either as JSON key or legacy prefix
        json_content, source = find_result_marker(source, stdout)

        unless json_content
          Logger.debug "[#{@log_tag}] [parse_result] ERROR: Marker not found in output!"
          Logger.debug "[#{@log_tag}] [parse_result] Last 500 chars: #{(source.from_text_content ? source.text : stdout).last(500)}"
          return error_result('No TASKRUNNER_RESULT found in output')
        end

        # Only unescape when parsing raw stream-json (text content is already clean)
        unless source.from_text_content
          json_content = json_content.gsub('\"', '"')
          json_content = json_content.gsub('\\\"', '\"')
        end

        Logger.debug "[#{@log_tag}] [parse_result] Final JSON content to parse: #{json_content}"

        begin
          result = JSON.parse(json_content).tap do |obj|
            obj.delete('TASKRUNNER_RESULT')
            obj['hours'] ||= {}
            obj['hours']['task_worked'] = elapsed_hours
          end
          result = post_parse_result(result) if respond_to?(:post_parse_result, true)
          Logger.debug "[#{@log_tag}] [parse_result] Successfully parsed result: #{result.inspect}"
          log_task_info(result)
          result
        rescue JSON::ParserError => e
          Logger.debug "[#{@log_tag}] [parse_result] ERROR: JSON parsing failed: #{e.message}"
          Logger.debug "[#{@log_tag}] [parse_result] Attempted to parse: #{json_content.inspect}"
          error_result("Failed to parse JSON: #{e.message}")
        end
      end

      # Searches for TASKRUNNER_RESULT in source text, trying JSON key format first, then legacy prefix.
      # Returns [json_string, source] or [nil, source].
      def find_result_marker(source, stdout)
        raw_source = ParseSource.new(text: stdout, from_text_content: false)

        # Try JSON key format: {"TASKRUNNER_RESULT": true, ...}
        json = extract_json_with_marker(source) { |text| find_json_key_marker(text) }
        return [json, source] if json

        if source.from_text_content
          json = extract_json_with_marker(raw_source) { |text| find_json_key_marker(text) }
          return [json, raw_source] if json
        end

        # Legacy prefix format: TASKRUNNER_RESULT: {json}
        json = extract_json_with_marker(source) { |text| find_legacy_prefix_marker(text) }
        return [json, source] if json

        if source.from_text_content
          json = extract_json_with_marker(raw_source) { |text| find_legacy_prefix_marker(text) }
          return [json, raw_source] if json
        end

        [nil, source]
      end

      def extract_json_with_marker(source)
        json_str = yield(source.text)
        return nil unless json_str

        json_end = find_json_end(json_str)
        return nil unless json_end

        json_str[0...json_end].strip
      end

      def find_json_key_marker(text)
        key_index = text.index('"TASKRUNNER_RESULT"')
        return nil unless key_index

        # Walk backward to find opening brace
        i = key_index - 1
        i -= 1 while i >= 0 && text[i] =~ /\s/
        return nil unless i >= 0 && text[i] == '{'

        Logger.debug "[#{@log_tag}] [parse_result] JSON key marker found at index #{key_index}"
        text[i..]
      end

      def find_legacy_prefix_marker(text)
        marker = 'TASKRUNNER_RESULT:'
        index = text.index(marker)
        return nil unless index

        after_marker = text[(index + marker.length)..]
        brace_index = after_marker.index('{')
        return nil unless brace_index

        Logger.debug "[#{@log_tag}] [parse_result] Legacy prefix marker found at index #{index}"
        after_marker[brace_index..]
      end

      def log_task_info(result)
        if result['task_info']
          Logger.debug '[parse_result] DEBUG: Extracted task_info:'
          Logger.debug "  - name: #{result['task_info']['name']}"
          Logger.debug "  - id: #{result['task_info']['id']}"
          Logger.debug "  - status: #{result['task_info']['status']}"
        end
        return unless result['hours']

        Logger.debug '[parse_result] DEBUG: Extracted hours:'
        Logger.debug "  - per_day: #{result['hours']['per_day']}"
        Logger.debug "  - task_estimated: #{result['hours']['task_estimated']}"
        Logger.debug "  - task_worked: #{result['hours']['task_worked']}"
      end

      def find_json_end(json_str)
        brace_count = 0
        i = 0

        while i < json_str.length
          char = json_str[i]

          if char == '\\'
            backslash_count = 0
            j = i
            while j < json_str.length && json_str[j] == '\\'
              backslash_count += 1
              j += 1
            end

            if j < json_str.length && json_str[j] == '"' && backslash_count.odd?
              i = j + 1
              next
            end
          end

          if char == '{'
            brace_count += 1
          elsif char == '}'
            brace_count -= 1
            return i + 1 if brace_count.zero?
          end

          i += 1
        end

        Logger.debug "[#{@log_tag}] [find_json_end] ERROR: JSON object not properly closed, final brace_count: #{brace_count}"
        nil
      end
    end
  end
end
