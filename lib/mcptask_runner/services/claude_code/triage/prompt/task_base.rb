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

              #{deferred_tools_note}

              #{branch_detection_step}

              STEP 2 - FETCH: #{mcp_fetch(task_fetch_url)}#{fetch_step_suffix}
              - No tasks → status "no_more_tasks", recommended_model="genius"
              - type="Story" → STEP 2b
              - type="Task" → STEP 3
              #{mcp_safety_note}

              STEP 2b - STORY:
              1. story_id = Story's relative_id
              2. First subtask: NOT "Schváleno"/"Hotovo?", progress<100
              3. None → status "no_more_tasks", recommended_model="genius", piece_type="Story"
              4. #{mcp_fetch("mcptask://pieces/#{account_code}/<subtask_id>")}
              5. STEP 3 with SUBTASK data
              6. Result: piece_type="Story", story_id=Story's relative_id, task_id=subtask's relative_id

              STEP 3 - ANALYZE: Read title, description, piece_type, attachment filenames (no downloads). Apply model rules below.

              #{model_selection_rules}

              #{result_format_instruction(
                '"status": "success", "recommended_model": "smart", "task_id": 123, "task_name": "Piece title", "resuming": false, "piece_type": "Task", "story_id": null',
                extra_rules: [
                  'recommended_model: "genius"/"smart"/"primitive" (lowercase)',
                  'task_id = relative_id of task (or subtask if Story)',
                  'task_name = piece title (or subtask title if Story); empty string if missing',
                  'resuming: boolean (not string)',
                  'piece_type: "Task" or "Story" (Story only if STEP 2b)',
                  'story_id: Story relative_id if piece_type="Story", else null'
                ]
              )}

              #{triage_status_instruction(status_entries: status_entries)}
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
              '- "no_more_tasks" if no tasks available'
          end
        end
      end
    end
  end
end
