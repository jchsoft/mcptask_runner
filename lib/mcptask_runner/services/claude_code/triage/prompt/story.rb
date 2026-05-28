# frozen_string_literal: true

require_relative 'base'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Triage prompt when story_id is given — picks first incomplete subtask, no branch detection.
        class Story < Base
          def initialize(story_id:, ignore_quota:)
            super(ignore_quota: ignore_quota)
            @story_id = story_id
          end

          def build
            <<~INSTRUCTIONS
              Task triage agent. Find next incomplete subtask from Story, recommend model.
              OUTPUT ONLY JSON. No explanations, no commentary.

              #{daily_quota_check_step}

              STEP 1 - LOAD STORY (MUST use /mcptask-read skill, NOT ReadMcpResourceTool):
              1. Invoke /mcptask-read with args: "load piece #{@story_id} with_attachments=false"
              2. Find subtasks
              3. First task: NOT "Schváleno"/"Hotovo?", progress<100
              4. None found → status "no_more_tasks", recommended_model="genius"
              5. Remember task relative_id

              STEP 2 - FETCH TASK via /mcptask-read: "load piece <task_relative_id> with_attachments=false"

              STEP 3 - ANALYZE: Read title, description, piece_type, attachment filenames (no downloads). Apply model rules below.

              #{model_selection_rules}

              #{result_format_instruction(
                '"status": "success", "recommended_model": "smart", "task_id": 123, "task_name": "Subtask title", "resuming": false, "hours": {"per_day": X, "task_estimated": Y, "already_worked": Z}',
                extra_rules: [
                  'recommended_model: "genius"/"smart"/"primitive" (lowercase)',
                  'task_id = subtask relative_id (NOT story)',
                  'task_name = subtask title; empty string if missing',
                  'resuming = false (story triage = fresh tasks)',
                  'already_worked = exact "worked_out" from mcptask://user — never 0 unless API returned 0'
                ]
              )}

              #{triage_hours_instruction(entity: 'subtask', status_entries: status_entries)}
            INSTRUCTIONS
          end

          private

          def status_entries
            "- \"success\" if subtask analyzed successfully\n" \
              "- \"no_more_tasks\" if no incomplete subtasks in the Story\n" \
              '- "quota_exceeded" if worked_out >= hour_goal (from STEP 0)'
          end
        end
      end
    end
  end
end
