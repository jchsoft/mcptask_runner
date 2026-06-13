# frozen_string_literal: true

module McptaskRunner
  module Concerns
    # Builds instruction text blocks for Claude prompts: git steps, coding conventions, result format, time management
    module InstructionBuilding
      private

      def triaged_git_step(resuming:)
        if resuming
          <<~STEP.strip
            1. RESUME TASK:
               - git branch --show-current
               - IF on feature branch:
                 → git fetch origin main && git merge origin/main
                 → Review git log + code state
               - IF on main/master:
                 → git branch --list "*<task_id>*"
                 → git checkout <branch_name>
                 → git fetch origin main && git merge origin/main
                 → Review git log + code state
               - SKIP steps 2-3, go to step 4 (IMPLEMENT)
          STEP
        else
          <<~STEP.strip
            1. GIT SETUP: git checkout main && git pull → step 2
          STEP
        end
      end

      def result_format_instruction(json_fields, extra_rules: [])
        rules = [
          'JSON inside ```json code block',
          '"TASKRUNNER_RESULT": true MUST be FIRST key',
          'Valid JSON — escape quotes as \\"',
          *extra_rules,
          'NO text after closing ```'
        ]

        numbered = rules.each_with_index.map { |rule, i| "#{i + 1}. #{rule}" }.join("\n")

        <<~INSTRUCTION.strip
          At the END, output the result as valid JSON in a code block:

          ```json
          {"TASKRUNNER_RESULT": true, #{json_fields}}
          ```

          CRITICAL FORMATTING:
          #{numbered}
        INSTRUCTION
      end

      def task_fetch_url
        if @task_id
          "mcptask://pieces/#{account_code}/#{@task_id}"
        else
          project_id = project_relative_id or raise 'project_relative_id not found in CLAUDE.md'
          "mcptask://pieces/#{account_code}/@next?project_relative_id=#{project_id}"
        end
      end

      def account_code
        raise 'CLAUDE.md not found — cannot resolve account_code' unless File.exist?('CLAUDE.md')

        File.read('CLAUDE.md').match(/account_code:\s*`?([\w-]+)`?/)&.then { |m| m[1] } \
          or raise 'account_code not found in CLAUDE.md (expected a line like: "- account_code: `myaccount`")'
      end

      # The runner snapshots the child's TodoWrite list to the mcptask.online dashboard
      # (SnapshotBuilder todo_list) — without one the card shows no plan/progress detail.
      def todo_list_instruction
        <<~INSTRUCTION.strip
          TODO LIST (MANDATORY): keep a live TodoWrite list of the workflow steps (in_progress/completed as you go) — the runner mirrors it to the dashboard.
        INSTRUCTION
      end

      def progress_logging_instruction
        <<~INSTRUCTION.strip
          PROGRESS LOGGING (MANDATORY — min 3× LogWorkProgressTool calls during run):
          - Single 100% call at end = UNACCEPTABLE. Caller sees no interim state.
          - Milestones (minimum cadence, bump progress_percent each time):
            a) After branch created + task understood → ~20%
            b) After implementation + unit tests pass → ~60%
            c) After PR/CI done → 100%
          - Each call: duration_minutes = minutes since previous call (not cumulative);
            description = what was done since last log.
          - More calls OK for long tasks; 3× is floor, not target.
        INSTRUCTION
      end

      def context_optimization_instruction
        <<~INSTRUCTION.strip
          EXPLORATION & OUTPUT (MANDATORY):
          - Explore with CodeGraph/LSP directly — skip the /discover, /memory-search skill wrappers (unreliable in this context). Call independent tools in parallel; never re-read a file already read.
          - Don't poll/retry in loops (each poll re-sends full history); size large files/logs before reading.
          - Be terse: no narration, no summaries of what you did (the user sees the diff). TASKRUNNER_RESULT JSON unchanged.
          - ALWAYS respond in English — even when the task description is in Czech or another language.
        INSTRUCTION
      end

      # Shared status option text for any executor that runs a task and might detect a NEW urgent
      # bug mid-work. Emit `urgent_bug_pending` so the runner switches to main and re-triages
      # globally (or exits a story-locked loop) to pick the urgent bug before resuming this task.
      def urgent_bug_pending_status_option
        <<~OPTION.strip
          - "urgent_bug_pending" if you discovered/created a NEW URGENT bug task during work that must be handled before continuing this task;
              BEFORE emitting this status:
                1. Commit + push current work on this task's branch (if any) — leaves PR/branch for human review or future resume
                2. `git checkout main` — leave clean working tree so runner picks the urgent bug, not this task
                3. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
                4. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
              Loop will exit (story-locked / explicit task / single-shot) or re-triage globally (today/queue) and pick the urgent bug.
        OPTION
      end

      def time_awareness_instruction
        <<~INSTRUCTION.strip
          TIME: >70 min elapsed → SKIP full tests/CI, run targeted tests only, then emit TASKRUNNER_RESULT. ALWAYS output TASKRUNNER_RESULT when done.
        INSTRUCTION
      end
    end
  end
end
