# frozen_string_literal: true

require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Handles PR review feedback - reads human reviews, creates subtasks, fixes issues
    class Review < ClaudeCodeBase
      def model_name = "smart"
      def max_turns = 100

      private

      def build_instructions
        [
          persona_section,
          task_section,
          workflow_section,
          output_format_section
        ].join("\n")
      end

      def persona_section
        persona_instruction
      end

      def task_section
        "[TASK] Fix PR review feedback on current branch.\n"
      end

      def workflow_section
        <<~WORKFLOW
          #{time_awareness_instruction}

          #{coding_conventions_instruction}

          WORKFLOW:
          #{git_state_check_step}
          #{pr_existence_check_step}
          #{extract_task_info_step}
          #{load_review_comments_step}
          #{create_subtask_step}
          #{fix_review_issues_step}
          #{commit_changes_step}
          #{run_unit_tests_step}
          #{run_system_tests_step}
          #{final_commit_step}
          #{push_step}
          #{run_local_ci_step}
        WORKFLOW
      end

      def git_state_check_step
        <<~STEP.strip
          1. GIT CHECK: git branch --show-current
             - main/master → STOP, error status
             - Feature branch → continue
        STEP
      end

      def pr_existence_check_step
        <<~STEP.strip
          2. PR CHECK: gh pr view --json number,title,body,url
             - No PR → STOP, error status
        STEP
      end

      def extract_task_info_step
        "3. TASK ID: Extract from PR body (mcptask.online/{account}/tasks/{id})"
      end

      def load_review_comments_step
        <<~STEP.strip
          4. LOAD REVIEWS:
             - gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews
             - gh api repos/{owner}/{repo}/pulls/{pr_number}/comments
             - Filter humans only. No reviews → status "no_reviews", STOP.
        STEP
      end

      def create_subtask_step
        <<~STEP.strip
          5. CREATE SUBTASK: CreatePieceTool under original task
             - Summarize review feedback in description
             - Log work progress
        STEP
      end

      def fix_review_issues_step
        "6. FIX ISSUES: Address all review problems. Follow CLAUDE.md rules."
      end

      def commit_changes_step
        "7. COMMIT: git add + commit referencing PR review"
      end

      def run_unit_tests_step
        "8. UNIT TESTS: /test-runner. Fix failures, repeat until pass."
      end

      def run_system_tests_step
        "9. SYSTEM TESTS: /test-runner. Fix failures, repeat until pass."
      end

      def final_commit_step
        "10. FINAL COMMIT: Commit remaining fixes"
      end

      def push_step
        "11. PUSH: git push origin HEAD"
      end

      def run_local_ci_step
        "12. LOCAL CI: bin/ci exists → /ci-runner. Otherwise skip."
      end

      def output_format_section
        <<~OUTPUT
          #{result_format_instruction(
            '"status": "success", "hours": {"per_day": X, "task_estimated": Y, "already_worked": Z}'
          )}

          #{status_values_section}
          #{hours_data_section}
        OUTPUT
      end

      def status_values_section
        <<~STATUS.strip
          Status: "success"=fixed+pushed, "no_reviews"=none found, "not_on_branch"=on main, "no_pr"=no PR, "failure"=other
        STATUS
      end

      def hours_data_section
        <<~HOURS.strip
          Hours:
          1. mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → "hour_goal"=per_day, "worked_out"=already_worked
             Read BEFORE logging work. WARNING: already_worked = daily "worked_out", NOT from effort history!
          2. task_estimated = 0.5 (reviews short)

          PROGRESS LOGGING (MANDATORY — min 3× LogWorkProgressTool calls during run):
          - Single 100% call at end = UNACCEPTABLE.
          - Milestones: after subtask created (~25%), after tests pass (~70%), after push+CI (100%).
          - duration_minutes = minutes since previous call; description = work since last log.
        HOURS
      end
    end
  end
end
