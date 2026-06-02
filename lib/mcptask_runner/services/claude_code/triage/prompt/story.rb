# frozen_string_literal: true

require_relative 'base'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Triage prompt when story_id is given — picks first incomplete subtask, no branch detection.
        class Story < Base
          def initialize(story_id:)
            @story_id = story_id
          end

          def build
            <<~INSTRUCTIONS
              Task triage agent. Find next incomplete subtask from Story, recommend model.
              OUTPUT ONLY JSON. No explanations, no commentary.

              STEP 1 - LOAD STORY:
              1. INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/#{account_code}/#{@story_id}" — DIRECT MCP. Do NOT use /mcptask-read skill.
              2. Find subtasks
              3. First task: NOT "Schváleno"/"Hotovo?", progress<100
              4. None found → status "no_more_tasks", recommended_model="genius"
              5. Remember task relative_id
              NEVER use Bash/curl/Net::HTTP — API uses internal id (not relative_id), returns WRONG piece. On MCP failure: STOP, emit error status.

              STEP 2 - FETCH TASK: INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/#{account_code}/<task_relative_id>" — DIRECT MCP, NOT /mcptask-read skill.

              STEP 3 - ANALYZE: Read title, description, piece_type, attachment filenames (no downloads). Apply model rules below.

              #{model_selection_rules}

              #{result_format_instruction(
                '"status": "success", "recommended_model": "smart", "task_id": 123, "task_name": "Subtask title", "resuming": false',
                extra_rules: [
                  'recommended_model: "genius"/"smart"/"primitive" (lowercase)',
                  'task_id = subtask relative_id (NOT story)',
                  'task_name = subtask title; empty string if missing',
                  'resuming = false (story triage = fresh tasks)'
                ]
              )}

              #{triage_status_instruction(status_entries: status_entries)}
            INSTRUCTIONS
          end

          private

          def status_entries
            "- \"success\" if subtask analyzed successfully\n" \
              '- "no_more_tasks" if no incomplete subtasks in the Story'
          end
        end
      end
    end
  end
end
