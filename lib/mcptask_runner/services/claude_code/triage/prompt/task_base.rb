# frozen_string_literal: true

require_relative 'base'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Shared scaffold for task-flavored triage prompts (TaskDiscovery, TaskPinned).
        # Subclasses provide branch_detection_step + fetch_step_suffix.
        class TaskBase < Base
          def build
            <<~INSTRUCTIONS
              Task triage agent. Analyze task, recommend model.
              OUTPUT ONLY JSON. No explanations, no commentary.

              #{daily_quota_check_step}

              #{branch_detection_step}

              STEP 2 - FETCH: #{task_fetch_url}#{fetch_step_suffix}
              - No tasks → status "no_more_tasks", recommended_model="opus"
              - type="Story" → STEP 2b
              - type="Task" → STEP 3

              STEP 2b - STORY:
              1. story_id = Story's relative_id
              2. First subtask: NOT "Schváleno"/"Hotovo?", progress<100
              3. None → status "no_more_tasks", recommended_model="opus", piece_type="Story"
              4. Fetch mcptask://pieces/jchsoft/<subtask_id>
              5. STEP 3 with SUBTASK data
              6. Result: piece_type="Story", story_id=Story's relative_id, task_id=subtask's relative_id

              STEP 3 - ANALYZE: Read title, description, piece_type, attachment filenames (no downloads). Apply model rules below.

              #{model_selection_rules}

              #{result_format_instruction(
                '"status": "success", "recommended_model": "sonnet", "task_id": 123, "task_name": "Piece title", "resuming": false, "piece_type": "Task", "story_id": null, "hours": {"per_day": X, "task_estimated": Y, "already_worked": Z}',
                extra_rules: [
                  'recommended_model: "opus"/"sonnet"/"haiku" (lowercase)',
                  'task_id = relative_id of task (or subtask if Story)',
                  'task_name = piece title (or subtask title if Story); empty string if missing',
                  'resuming: boolean (not string)',
                  'piece_type: "Task" or "Story" (Story only if STEP 2b)',
                  'story_id: Story relative_id if piece_type="Story", else null',
                  'already_worked = exact "worked_out" — never 0 unless API returned 0'
                ]
              )}

              #{triage_hours_instruction(entity: 'task', status_entries: status_entries)}
            INSTRUCTIONS
          end

          private

          def fetch_step_suffix
            ''
          end

          def branch_detection_step
            raise NotImplementedError, "#{self.class} must implement #branch_detection_step"
          end

          def status_entries
            "- \"success\" if task analyzed successfully\n" \
              "- \"no_more_tasks\" if no tasks available\n" \
              '- "quota_exceeded" if worked_out >= hour_goal (from STEP 0)'
          end
        end
      end
    end
  end
end
