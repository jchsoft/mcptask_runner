# frozen_string_literal: true

require_relative 'review'

module McptaskRunner
  module ClaudeCode
    # Handles ONE PR review - finds next PR with reviews, checks out branch, fixes issues
    # Called in a loop by WorkLoop to process multiple PRs with fresh context each time
    class Reviews < Review
      private

      def task_section
        "[TASK] Find next PR with unaddressed review. Checkout branch, fix, return. Loops until no reviews.\n"
      end

      def workflow_section
        <<~WORKFLOW
          #{time_awareness_instruction}

          WORKFLOW:
          #{find_next_pr_with_review_step}
          #{checkout_branch_step}
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

      def find_next_pr_with_review_step
        <<~STEP.strip
          1. FIND PR WITH REVIEW:
             - gh pr list --json number,title,headRefName,url --state open
             - For each: gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews
             - Filter humans. First unaddressed review.
             - None found → status "no_reviews", STOP.
        STEP
      end

      def checkout_branch_step
        "2. CHECKOUT: git fetch origin {branch} && git checkout {branch} && git pull origin {branch}"
      end

      def load_review_comments_step
        <<~STEP.strip
          4. LOAD REVIEWS:
             - gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews
             - gh api repos/{owner}/{repo}/pulls/{pr_number}/comments
             - Most recent human review.
        STEP
      end

      def create_subtask_step
        <<~STEP.strip
          5. CREATE SUBTASK: CreatePieceTool under original task
             - Summarize review feedback. Log progress.
        STEP
      end

      def run_unit_tests_step
        "8. UNIT TESTS: Run suite. Fix failures, repeat until pass."
      end

      def run_system_tests_step
        "9. SYSTEM TESTS: Run (~5 min). Fix failures, repeat until pass."
      end

      def run_local_ci_step
        "12. LOCAL CI: bin/ci exists → run it"
      end

      def status_values_section
        "Status: \"success\"=fixed+pushed, \"no_reviews\"=none found, \"failure\"=error"
      end
    end
  end
end
