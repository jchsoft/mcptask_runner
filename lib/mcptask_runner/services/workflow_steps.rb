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

    # Canonical piece-fetch directive, shared by every step that loads a piece.
    #
    # Tool deferral is HOST-DEPENDENT, so the ROUTE to ReadMcpResourceTool cannot be stated flatly
    # (same split Triage::Prompt::Base#tool_availability_note handles):
    #   * native Anthropic host — tool search is on, the tool is DEFERRED (named in a reminder, no
    #     schema). A direct call answers "exists but is not enabled in this context", which
    #     StreamProcessing#check_for_tool_not_enabled treats as an MCP outage and kills the attempt.
    #     ToolSearch must come first here.
    #   * ANTHROPIC_BASE_URL proxy (ollama/qwen, see LauncherConfig) — there is no ToolSearch tool at
    #     all and every MCP tool is already active. The old wording ordered ToolSearch FIRST
    #     unconditionally, so a qwen child got "No such tool available: ToolSearch", then improvised
    #     `curl /api/v1/pieces/<relative_id>` (403), and only then called ReadMcpResourceTool
    #     directly — which worked on the first try. Two wasted turns and an invented HTTP route.
    # The discriminator that holds on both hosts is whether ToolSearch itself exists, so the rule is
    # phrased on that, not on "is the tool in my list" (a deferred tool IS named in the list).
    #
    # Which is also why the lead line says WHICH TOOL and WHICH TRANSPORT but never "call it first":
    # ordering is exactly the host-dependent part. An earlier draft led with "DIRECT MCP call, the
    # FIRST route you try" — a child that acts on that headline without reading the two sub-bullets
    # commits to the direct call on a deferring host, which is the fatal path above. "DIRECT" was
    # only ever meant as "MCP, not REST", so it is spelled that way now.
    #
    # The deferred branch quotes the marker SHORT ("not enabled in this context"), never the full
    # 'exists but is not enabled in this context' StreamProcessing#tool_not_enabled_error? matches on:
    # that detector still fires on an is_error tool_result echoing the phrase, so a failing command
    # that happens to print this prompt back (a red `bin/ci`, a diff) would kill its own session.
    #
    # REST is never a fallback: Api::PiecesController#show does `Piece.find(params[:id])` — an
    # INTERNAL id — so a relative_id there answers a foreign piece or 403 forbidden.
    def mcp_fetch_lines(indent, uri)
      [
        %(#{indent}- FETCH IT WITH ReadMcpResourceTool: server="mcptask-online", uri="#{uri}" — the MCP route, never REST. HOW you reach that tool depends on the host, so pick your branch BEFORE calling:),
        %(#{indent}  - You have NO ToolSearch tool → this host defers nothing, ReadMcpResourceTool is live: CALL IT DIRECTLY, no lookup step.),
        %(#{indent}  - You HAVE ToolSearch and ReadMcpResourceTool is only NAMED (no schema loaded) → it is DEFERRED, which is NOT missing and NOT an MCP failure: ToolSearch query "select:ReadMcpResourceTool" FIRST, THEN invoke it. Calling it directly here answers "not enabled in this context" and kills the attempt.),
        %(#{indent}- NEVER Bash/curl/Net::HTTP, NEVER the /mcptask-read skill: REST takes the INTERNAL id, so a relative_id there returns the WRONG piece or 403. "Tool not available" is never a reason to improvise a fetch route or to fail.)
      ]
    end

    def task_fetch_step(step_num:, fetch_url:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. TASK FETCH:
        #{mcp_fetch_lines(s, fetch_url).join("\n")}
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
        #{step_num}. LOAD TASK:
        #{mcp_fetch_lines(s, "mcptask://pieces/#{account_code}/#{task_id}").join("\n")}
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
          1. LOAD STORY:
          #{mcp_fetch_lines('   ', "mcptask://pieces/#{account_code}/#{story_id}").join("\n")}
             - Review name, description, subtasks
             - Note completed subtasks for context
             - Work on task ##{task_id} (pre-selected by triage)
        STEP
      end

      <<~STEPS.chomp
        #{story_step}

        2. LOAD TASK:
        #{mcp_fetch_lines('   ', "mcptask://pieces/#{account_code}/#{task_id}").join("\n")}
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
        #{step_num}. CREATE BRANCH (resume existing first — use the fetched task's ID):
        #{s}- Check for an existing branch for this task: git branch --list "*<task_id>*"
        #{s}- MATCH → git checkout <branch_name> && git fetch origin main && git merge origin/main (RESUME existing work; do NOT create a duplicate)
        #{s}- NO MATCH → create: "feature/{task_id}-{desc}" or "fix/{task_id}-{desc}", then git checkout -b <branch-name>
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
      lines << "#{step_num}. CREATE PULL REQUEST:#{title_suffix}"
      lines << "#{s}- Follow #{pr_template_path} if it exists"
      lines << "#{s}- Clear summary + mcptask.online task link"
      lines << "#{s}- Do NOT merge — human review only" if no_merge_warning
      lines << "#{s}- Auto-merge after CI passes" if auto_merge_note
      lines.join("\n")
    end

    def add_screenshots_to_pr_step(step_num:)
      s = step_indent(step_num)
      <<~STEP.strip
        #{step_num}. PR SCREENSHOTS: Take a screenshot in the system test and add it to the PR
        #{s}- Ensure screenshot shows tested feature (not test failure)
      STEP
    end

    def skip_screenshots_step(step_num:)
      "#{step_num}. SKIP screenshots (autosquash)"
    end

    def preexisting_test_errors_instruction
      bug_dest = bug_destination_line
      <<~INSTRUCTION.strip
        PREEXISTING TEST ERRORS (CRITICAL):
        If tests fail in code you did NOT modify:
        1. Verify: git stash → run tests on main → git stash pop
        2. Fail without your changes = PREEXISTING
        3. Create URGENT bug task:
           - mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → get relative_id
           - CreatePieceTool: account_code=<from CLAUDE.md>, piece_type="Task", task_type_code="bug",
             priority_code="urgent", project_id=<from CLAUDE.md>, assigned_user_id=<relative_id>
             #{bug_dest}name="Fix: Padající testy - <description>"
             description: failing tests, errors, branch/commit, interrupted task ID
        4. git checkout main (keep feature branch)
        5. Status "preexisting_test_errors"
        6. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
        7. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
        8. Do NOT fix them — only create bug task

        NOT preexisting but CI still red (tests PASS on main without your changes, yet bin/ci
        fails — flake, environment, or cannot reproduce): this is NOT "success". No signoff
        was posted, so the PR cannot merge. Do NOT merge and do NOT claim it merged. If you
        cannot get bin/ci to exit 0 after retry → status "ci_failed" (PR stays open).
      INSTRUCTION
    end

    # Returns either a `parent_id: <id>, ` line for inclusion in the bug-piece
    # CreatePieceTool call, or an empty string when no destination is configured.
    # The trailing space is intentional so concatenation in the heredoc reads naturally.
    def bug_destination_line
      cfg = bug_destination_config
      return '' unless cfg[:epic_relative_id].is_a?(Integer) && cfg[:epic_relative_id].positive?

      label = cfg[:epic_name] ? " \"#{cfg[:epic_name]}\"" : ''
      "parent_id: #{cfg[:epic_relative_id]},   # auto-bugs land in this Epic#{label}\n             "
    end

    def bug_destination_config
      require 'mcptask_runner/services/concerns/bug_destination_config'
      Concerns::BugDestinationConfig.load
    rescue LoadError
      { epic_relative_id: nil, epic_name: nil }
    end

    def pr_template_path
      require 'mcptask_runner/services/concerns/pr_template_config'
      Concerns::PrTemplateConfig.load[:path]
    rescue LoadError
      Concerns::PrTemplateConfig::DEFAULT_PATH
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
