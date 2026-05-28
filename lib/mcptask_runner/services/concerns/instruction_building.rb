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

      def branch_resume_check_step(project_id:, pull_on_main: true)
        pull_cmd = pull_on_main ? 'git checkout main && git pull' : 'git checkout main'
        <<~STEP.strip
          1. GIT STATE + RESUME CHECK:
             - git branch --show-current
             - IF main/master: #{pull_cmd} → step 2
             - IF feature branch:
               a) Extract task ID from branch name (e.g. "feature/9508-contact-page" → 9508)
                  Found → read mcptask://pieces/jchsoft/{task_id}
               b) No ID → check PR: gh pr list --head $(git branch --show-current) --json body --jq '.[0].body'
                  Look for mcptask.online link → extract task ID → load task
               c) Still nothing → #{pull_cmd} → step 2
               d) CHECK PROGRESS (if task found):
                  - progress >= 100 or state "Schváleno"/"Hotovo?" → #{pull_cmd} → step 2
                  - progress < 100 → RESUME: TASKRUNNER_TASK_INFO, SKIP steps 2-3, go to step 4
        STEP
      end

      def coding_conventions_instruction
        <<~INSTRUCTION.strip
          CODING CONVENTIONS (MANDATORY):
          - GIT COMMITS: NEVER use $() in commit messages. Plain quoted strings:
            ✅ git commit -m "Fix login validation for empty emails"
            ❌ git commit -m "$(echo 'Fix login')"
            Multi-line → heredoc:
            git commit -m "$(cat <<'EOF'
            Your message here.
            EOF
            )"
          - RUBOCOP BEFORE CI: git diff --name-only main -- '*.rb' | xargs rubocop -a
        INSTRUCTION
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

      def persona_instruction
        '[PERSONA] Senior Ruby on Rails dev. Follow RubyWay.'
      end

      def task_fetch_url
        if @task_id
          "mcptask://pieces/jchsoft/#{@task_id}"
        else
          project_id = project_relative_id or raise 'project_relative_id not found in CLAUDE.md'
          "mcptask://pieces/jchsoft/@next?project_relative_id=#{project_id}"
        end
      end

      def hours_data_instruction(include_warning: false)
        warning = if include_warning
                    "\n   WARNING: already_worked = daily \"worked_out\" (e.g. 3.0). NOT from effort minutes/history!"
        else
                    ''
        end
        <<~INSTRUCTION.strip
          Hours data:
          1. mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → "hour_goal"=per_day, "worked_out"=already_worked
             Read BEFORE logging work progress#{warning}
          2. Task "duration_best" → task_estimated (e.g. "1 hodina" → 1.0)

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
          CONTEXT OPTIMIZATION (MANDATORY):
          - Call independent tools in parallel (Read/Grep/Glob in one turn)
          - CodeGraph/LSP BEFORE Read/Grep for exploration
          - If CodeGraph unavailable, LSP as primary:
            * documentSymbol — file structure
            * findReferences — callers
            * definition — jump to def
            * incomingCalls — call graph
          - Never re-read same file >2×. Use offset+limit for re-reads.

          PATIENCE & CONTEXT BURN (MANDATORY):
          - Long waits (CI, system tests, other Claude agent) → be patient. No polling loops,
            no repeated status checks, no retries "just to see". Each poll re-sends full history.
          - Large files / logs → never Read whole. Size first (wc -l), then tail/grep/offset+limit.
          - Never repeat the same operation hoping for different result. One failure = diagnose, not retry.

          OUTPUT EFFICIENCY (MANDATORY — saves ~65% tokens):
          - Drop filler: just/really/basically/actually/simply/certainly
          - Drop pleasantries: "Sure!"/"Happy to help"/"Let me..."/"I'll proceed to..."
          - No hedging: maybe/perhaps/might be worth
          - Short fragments. Pattern: [thing] [action] [reason].
          - NEVER explain what you're about to do — do it. Never narrate tool calls.
          - NEVER summarize what you did — user sees diff.
          - Technical terms exact. Code blocks unchanged. Errors quoted exact.
          - TASKRUNNER_RESULT JSON unchanged — rules apply to natural language only.
          - ALWAYS respond in English — even when task description is in Czech or other language.
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
                3. Add field "bug_task_id": <relative_id of the urgent bug task you created>
              Loop will exit (story-locked / explicit task / single-shot) or re-triage globally (today/queue) and pick the urgent bug.
        OPTION
      end

      def time_awareness_instruction
        <<~INSTRUCTION.strip
          TIME MANAGEMENT (CRITICAL):
          - Target: 90 min. Kill: 20 min inactive (no stream output).
          - Producing output = safe.
          - >70 min elapsed → SKIP full tests/CI. Run targeted tests only → TASKRUNNER_RESULT.
          - ALWAYS output TASKRUNNER_RESULT when done.
        INSTRUCTION
      end
    end
  end
end
