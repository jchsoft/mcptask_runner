# frozen_string_literal: true

module McptaskRunner
  # Shared workflow step definitions for implementation workflows.
  # Included by AutoSquashBase and manual workflow classes (Honest, TaskManual, StoryManual).
  # Each method returns a formatted step string ready for embedding in instructions.
  module WorkflowSteps
    private

    # Sub-item indentation: 3 spaces for steps 1-9, 4 for 10+
    def step_indent(step_num)
      step_num < 10 ? '   ' : '    '
    end

    def task_fetch_step(step_num:, fetch_url:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. TASK FETCH:
        #{s}- INVOKE ReadMcpResourceTool with server="mcptask-online", uri="#{fetch_url}" — DIRECT MCP call. Do NOT use /mcptask-read skill (unreliable in this context). NEVER Bash/curl/Net::HTTP — API uses internal id, returns WRONG piece.
        #{s}- No tasks → STOP, status "no_more_tasks"
        #{s}- Verify not started/completed
        #{s}- Output:
        #{s}  TASKRUNNER_TASK_INFO:
        #{s}  ID: <relative_id>
        #{s}  TITLE: <task name>
        #{s}  DESCRIPTION: <first 200 chars>
        #{s}  END_TASK_INFO
      STEP
    end

    def load_task_step(step_num:, task_id:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. LOAD TASK: INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/#{account_code}/#{task_id}" — DIRECT MCP call. Do NOT use /mcptask-read skill. NEVER Bash/curl/Net::HTTP.
        #{s}- Output:
        #{s}  TASKRUNNER_TASK_INFO:
        #{s}  ID: <relative_id>
        #{s}  TITLE: <task name>
        #{s}  DESCRIPTION: <first 200 chars>
        #{s}  END_TASK_INFO
      STEP
    end

    def story_task_discovery_steps(story_id:, task_id:, skip_story_load: false)
      story_step = if skip_story_load
        <<~STEP.chomp
          1. STORY CONTEXT: Story ##{story_id} already loaded. Skip → step 2. Task: ##{task_id}.
        STEP
      else
        <<~STEP.chomp
          1. LOAD STORY: INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/#{account_code}/#{story_id}" — DIRECT MCP. Do NOT use /mcptask-read skill.
             - Review name, description, subtasks
             - Note completed subtasks for context
             - Work on task ##{task_id} (pre-selected by triage)
        STEP
      end

      <<~STEPS.chomp
        #{story_step}

        2. LOAD TASK: INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/#{account_code}/#{task_id}" — DIRECT MCP. Do NOT use /mcptask-read skill. NEVER Bash/curl/Net::HTTP.
           - progress > 0: CONTINUATION → skip steps 3-4, go to step 5
           - progress = 0: proceed normally
           - Output:
             TASKRUNNER_TASK_INFO:
             ID: <relative_id>
             TITLE: <task name>
             DESCRIPTION: <first 200 chars>
             END_TASK_INFO
      STEPS
    end

    def create_branch_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. CREATE BRANCH:
        #{s}- Include task ID: "feature/{task_id}-{desc}" or "fix/{task_id}-{desc}"
        #{s}- git checkout -b <branch-name>
      STEP
    end

    def implement_task_step(step_num:)
      "#{step_num}. IMPLEMENT TASK (incremental commits, clear messages)"
    end

    def run_unit_tests_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. UNIT TESTS:
        #{s}- Invoke /test-runner
        #{s}- Fix failures, commit. Repeat until pass.
      STEP
    end

    def compile_test_assets_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. COMPILE TEST ASSETS:
        #{s}- bin/rails assets:precompile RAILS_ENV=test
      STEP
    end

    def prepare_screenshots_step(step_num:, special_method_hint: false)
      s = step_indent(step_num)
      lines = []
      lines << "#{step_num}. SCREENSHOTS:"
      lines << "#{s}- Save from system tests with visual changes"
      lines << "#{s}- Ensure screenshot shows tested feature (scroll if needed)"
      lines << "#{s}- Check ApplicationSystemTestCase for **special method**" if special_method_hint
      lines.join("\n")
    end

    def run_system_tests_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. SYSTEM TESTS:
        #{s}- Invoke /test-runner for system tests
        #{s}- Fix failures, commit. Repeat until pass.
      STEP
    end

    def verify_tests_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. VERIFY TESTS: Re-run all via /test-runner
        #{s}- Unit + system tests. Repeat until all pass.
      STEP
    end

    def push_step(step_num:, set_upstream: true)
      push_cmd = set_upstream ? 'git push -u origin HEAD' : 'git push origin HEAD'
      "#{step_num}. PUSH: #{push_cmd}"
    end

    def create_pr_step(step_num:, no_merge_warning: false, auto_merge_note: false)
      s = step_indent(step_num)
      title_suffix = no_merge_warning ? ' (NO MERGE!)' : ''
      lines = []
      lines << "#{step_num}. CREATE PR:#{title_suffix}"
      lines << "#{s}- Use .github/pull_request_template.md if exists"
      lines << "#{s}- Clear summary + mcptask.online task link"
      lines << "#{s}- Do NOT merge — human review only" if no_merge_warning
      lines << "#{s}- Auto-merge after CI passes" if auto_merge_note
      lines.join("\n")
    end

    def add_screenshots_to_pr_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. PR SCREENSHOTS: Invoke /pr-screenshot
        #{s}- Ensure screenshot shows tested feature (not test failure)
      STEP
    end

    def skip_screenshots_step(step_num:)
      "#{step_num}. SKIP screenshots (autosquash)"
    end

    def preexisting_test_errors_instruction
      <<~INSTRUCTION.strip
        PREEXISTING TEST ERRORS (CRITICAL):
        If tests fail in code you did NOT modify:
        1. Verify: git stash → run tests on main → git stash pop
        2. Fail without your changes = PREEXISTING
        3. Create URGENT bug task:
           - mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → get relative_id
           - CreatePieceTool: account_code=<from CLAUDE.md>, piece_type="Task", task_type_code="bug",
             priority_code="urgent", project_id=<from CLAUDE.md>, assigned_user_id=<relative_id>
             name="Fix: Padající testy - <description>"
             description: failing tests, errors, branch/commit, interrupted task ID
        4. git checkout main (keep feature branch)
        5. Status "preexisting_test_errors"
        6. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
        7. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
        8. Do NOT fix them — only create bug task
      INSTRUCTION
    end

    def run_local_ci_step(step_num:, verify_step_ref: nil)
      s = step_indent(step_num)
      lines = []
      lines << "#{step_num}. LOCAL CI (MANDATORY):"
      lines << "#{s}- No bin/ci → skip"
      lines << "#{s}- Tests failed in step #{verify_step_ref} → skip" if verify_step_ref
      lines << "#{s}- Invoke /ci-runner"
      lines.join("\n")
    end
  end
end
