# frozen_string_literal: true

require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Dry run - only loads and displays task information, no modifications
    class Dry < ClaudeCodeBase
      def model_name = "primitive"
      def max_turns = 30

      private

      def accept_edits?
        false # Dry run should not modify files
      end

      def build_instructions
        project_id = project_relative_id or raise 'project_relative_id not found in CLAUDE.md'

        <<~INSTRUCTIONS
          DRY RUN — display task from: mcptask://pieces/#{account_code}/@next?project_relative_id=#{project_id}

          1. Fetch piece
          2. type="Story" → 2b. type="Task" → 2c
          2b. STORY: Display info, list subtasks
             - First subtask NOT "Schváleno"/"Hotovo?", progress<100
             - Found → fetch mcptask://pieces/#{account_code}/<subtask_id>, display
             - Result: piece_type="Story", story_id=Story's relative_id, task_info from SUBTASK
          2c. Output:
             TASKRUNNER_TASK_INFO:
             ID: <relative_id>
             TITLE: <task name>
             DESCRIPTION: <first 200 chars>
             END_TASK_INFO
          3-5. NO branch, NO code changes, NO PR

          [DEBUG] duration_best: '<original_value>' -> task_estimated: Y

          #{result_format_instruction(
            '"status": "success", "piece_type": "Task", "story_id": null, "task_info": {"name": "...", "id": 123, "description": "...", "status": "...", "priority": "...", "assigned_user": "...", "scrum_points": "..."}, "hours": {"per_day": X, "task_estimated": Y, "already_worked": Z}'
          )}

          Data:
          1. mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → "hour_goal"=per_day, "worked_out"=already_worked
             Read BEFORE logging work. WARNING: already_worked = daily "worked_out", NOT from effort history!
          2. From task: name, relative_id (as id), description, task_state (as status), priority, assigned_user, scrum_point (as scrum_points)
          3. task_estimated from "duration_best": hodina/hours→hours, den/day→×8, tyden/week→×40
             Range (e.g. "3.0 - 7.0 hodin") → use smallest (3.0)
          4. status: "success" if loaded
        INSTRUCTIONS
      end
    end
  end
end
