# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeHonestTest < Minitest::Test
  def test_honest_responds_to_run
    honest = McptaskRunner::ClaudeCode::Honest.new
    assert_respond_to honest, :run
  end

  def test_honest_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::Honest < McptaskRunner::ClaudeCodeBase
  end

  def test_honest_uses_genius_model
    honest = McptaskRunner::ClaudeCode::Honest.new
    assert_equal 'genius', honest.send(:model_name)
  end

  def test_honest_accepts_edits
    honest = McptaskRunner::ClaudeCode::Honest.new
    assert honest.send(:accept_edits?)
  end

  def test_instructions_includes_project_id
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'project_relative_id=99'
        assert_includes instructions, 'mcptask://pieces/jchsoft/@next'
        assert_includes instructions, 'TASKRUNNER_RESULT'
      end
    end
  end

  def test_instructions_includes_todo_list_mandate
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'TODO LIST (MANDATORY)'
        assert_includes instructions, 'TodoWrite'
      end
    end
  end

  def test_instructions_includes_git_checkout_main
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'git checkout main && git pull'
        refute_includes instructions, 'GIT STATE + RESUME CHECK'
      end
    end
  end

  def test_instructions_raises_when_project_id_not_found
    File.stub :exist?, false do
      honest = McptaskRunner::ClaudeCode::Honest.new
      assert_raises(RuntimeError) do
        honest.send(:build_instructions)
      end
    end
  end

  def test_instructions_includes_task_status_check
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=7\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'not started/completed'
      end
    end
  end

  def test_instructions_includes_workflow_steps
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'CREATE BRANCH'
        assert_includes instructions, 'IMPLEMENT TASK'
        assert_includes instructions, 'incremental commits'
        assert_includes instructions, 'UNIT TESTS'
        assert_includes instructions, 'SYSTEM TESTS'
        assert_includes instructions, 'PUSH'
        assert_includes instructions, 'CREATE PR'
      end
    end
  end

  def test_instructions_uses_test_runner_skill
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'test-runner'
        assert_includes instructions, '/test-runner'
      end
    end
  end

  def test_instructions_ci_step_uses_ci_runner_skill
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'ci-runner'
        assert_includes instructions, '/ci-runner'
        refute_includes instructions, 'run_in_background'
        refute_includes instructions, 'poll every 5 minutes'
      end
    end
  end

  def test_instructions_uses_plain_git_setup
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        honest = McptaskRunner::ClaudeCode::Honest.new
        instructions = honest.send(:build_instructions)
        assert_includes instructions, 'GIT SETUP: git checkout main && git pull'
        refute_includes instructions, 'GIT STATE + RESUME CHECK'
      end
    end
  end
end

class ClaudeCodeDryTest < Minitest::Test
  def test_dry_responds_to_run
    dry = McptaskRunner::ClaudeCode::Dry.new
    assert_respond_to dry, :run
  end

  def test_dry_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::Dry < McptaskRunner::ClaudeCodeBase
  end

  def test_dry_uses_haiku_model
    dry = McptaskRunner::ClaudeCode::Dry.new
    assert_equal 'primitive', dry.send(:model_name)
  end

  def test_dry_does_not_accept_edits
    dry = McptaskRunner::ClaudeCode::Dry.new
    refute dry.send(:accept_edits?)
  end

  def test_instructions_dry_includes_project_id
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=77\naccount_code: `jchsoft`" do
        dry = McptaskRunner::ClaudeCode::Dry.new
        instructions = dry.send(:build_instructions)
        assert_includes instructions, 'project_relative_id=77'
        assert_includes instructions, 'mcptask://pieces/jchsoft/@next'
        assert_includes instructions, 'TASKRUNNER_RESULT'
        assert_includes instructions, 'DRY RUN'
        assert_includes instructions, 'NO branch'
      end
    end
  end

  def test_instructions_dry_includes_task_info_fields
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=77\naccount_code: `jchsoft`" do
        dry = McptaskRunner::ClaudeCode::Dry.new
        instructions = dry.send(:build_instructions)
        assert_includes instructions, 'task_info'
        assert_includes instructions, 'name'
        assert_includes instructions, 'description'
        assert_includes instructions, 'status'
        assert_includes instructions, 'priority'
      end
    end
  end

  def test_instructions_dry_raises_when_project_id_not_found
    File.stub :exist?, false do
      dry = McptaskRunner::ClaudeCode::Dry.new
      assert_raises(RuntimeError) do
        dry.send(:build_instructions)
      end
    end
  end

  def test_instructions_dry_reports_task_info_without_quota
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=77\naccount_code: `jchsoft`" do
        dry = McptaskRunner::ClaudeCode::Dry.new
        instructions = dry.send(:build_instructions)
        assert_includes instructions, 'TASKRUNNER_TASK_INFO'
        assert_includes instructions, 'task_info'
        assert_includes instructions, 'NO branch, NO code changes, NO PR'
        refute_includes instructions, 'worked_out'
      end
    end
  end

  def test_instructions_dry_prevents_modifications
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=77\naccount_code: `jchsoft`" do
        dry = McptaskRunner::ClaudeCode::Dry.new
        instructions = dry.send(:build_instructions)
        assert_includes instructions, 'NO branch'
        assert_includes instructions, 'NO code changes'
        assert_includes instructions, 'NO PR'
      end
    end
  end

  def test_instructions_dry_includes_story_detection
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=77\naccount_code: `jchsoft`" do
        dry = McptaskRunner::ClaudeCode::Dry.new
        instructions = dry.send(:build_instructions)
        assert_includes instructions, 'STORY'
        assert_includes instructions, 'piece_type'
        assert_includes instructions, 'story_id'
        assert_includes instructions, '"piece_type": "Task"'
      end
    end
  end
end

class ClaudeCodeReviewTest < Minitest::Test
  def test_review_responds_to_run
    review = McptaskRunner::ClaudeCode::Review.new
    assert_respond_to review, :run
  end

  def test_review_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::Review < McptaskRunner::ClaudeCodeBase
  end

  def test_review_uses_sonnet_model
    review = McptaskRunner::ClaudeCode::Review.new
    assert_equal 'smart', review.send(:model_name)
  end

  def test_review_accepts_edits
    review = McptaskRunner::ClaudeCode::Review.new
    assert review.send(:accept_edits?)
  end

  def test_review_instructions_includes_git_state_check
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'GIT CHECK'
    assert_includes instructions, 'main/master'
    assert_includes instructions, 'git branch --show-current'
  end

  def test_review_instructions_includes_pr_check
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'PR CHECK'
    assert_includes instructions, 'gh pr view'
  end

  def test_review_instructions_includes_review_loading
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'LOAD REVIEWS'
    assert_includes instructions, 'humans only'
    assert_includes instructions, 'pulls/{pr_number}/reviews'
    assert_includes instructions, 'pulls/{pr_number}/comments'
  end

  def test_review_instructions_includes_fix_workflow
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'FIX ISSUES'
    assert_includes instructions, 'COMMIT'
    assert_includes instructions, 'UNIT TESTS'
    assert_includes instructions, 'SYSTEM TESTS'
    assert_includes instructions, 'PUSH'
  end

  def test_review_instructions_includes_wvrunner_result
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'status'
    assert_includes instructions, 'PROGRESS LOGGING'
  end

  def test_review_instructions_includes_status_values
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'success'
    assert_includes instructions, 'no_reviews'
    assert_includes instructions, 'not_on_branch'
    assert_includes instructions, 'no_pr'
    assert_includes instructions, 'failure'
  end

  def test_review_instructions_includes_mcptask_task_extraction
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'TASK ID'
    assert_includes instructions, 'mcptask.online'
  end

  def test_review_instructions_includes_subtask_creation
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'CREATE SUBTASK'
    assert_includes instructions, 'CreatePieceTool'
  end

  def test_review_instructions_uses_test_runner_skill
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'test-runner'
    assert_includes instructions, '/test-runner'
  end

  def test_review_instructions_ci_step_uses_ci_runner_skill
    review = McptaskRunner::ClaudeCode::Review.new
    instructions = review.send(:build_instructions)
    assert_includes instructions, 'ci-runner'
    assert_includes instructions, '/ci-runner'
    refute_includes instructions, 'run_in_background'
  end
end

class ClaudeCodeReviewsTest < Minitest::Test
  def test_reviews_responds_to_run
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    assert_respond_to reviews, :run
  end

  def test_reviews_inherits_from_review
    assert McptaskRunner::ClaudeCode::Reviews < McptaskRunner::ClaudeCode::Review
  end

  def test_reviews_uses_sonnet_model
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    assert_equal 'smart', reviews.send(:model_name)
  end

  def test_reviews_accepts_edits
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    assert reviews.send(:accept_edits?)
  end

  def test_reviews_instructions_includes_find_next_pr_step
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    instructions = reviews.send(:build_instructions)
    assert_includes instructions, 'FIND PR WITH REVIEW'
    assert_includes instructions, 'gh pr list'
    assert_includes instructions, '--state open'
  end

  def test_reviews_instructions_includes_checkout_branch
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    instructions = reviews.send(:build_instructions)
    assert_includes instructions, 'CHECKOUT'
    assert_includes instructions, 'git fetch'
    assert_includes instructions, 'git checkout'
  end

  def test_reviews_mentions_called_repeatedly_in_loop
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    instructions = reviews.send(:build_instructions)
    assert_includes instructions, 'Loops until no reviews'
  end

  def test_reviews_instructions_includes_fix_workflow
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    instructions = reviews.send(:build_instructions)
    assert_includes instructions, 'FIX ISSUES'
    assert_includes instructions, 'COMMIT'
    assert_includes instructions, 'UNIT TESTS'
    assert_includes instructions, 'SYSTEM TESTS'
    assert_includes instructions, 'PUSH'
  end

  def test_reviews_instructions_includes_wvrunner_result
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    instructions = reviews.send(:build_instructions)
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'status'
    assert_includes instructions, 'PROGRESS LOGGING'
  end

  def test_reviews_has_different_task_section_than_review
    review = McptaskRunner::ClaudeCode::Review.new
    reviews = McptaskRunner::ClaudeCode::Reviews.new

    review_task = review.send(:task_section)
    reviews_task = reviews.send(:task_section)

    refute_equal review_task, reviews_task
    assert_includes reviews_task, 'next PR with unaddressed review'
  end

  def test_reviews_handles_single_pr_per_call
    reviews = McptaskRunner::ClaudeCode::Reviews.new
    instructions = reviews.send(:build_instructions)
    # Reviews now handles single PR per call, loop is in WorkLoop
    refute_includes instructions, 'not_on_branch'  # Does not check current branch
    refute_includes instructions, 'no_pr'  # Does not check current PR existence
    assert_includes instructions, 'First unaddressed'  # Finds first PR with reviews
  end
end

class ClaudeCodeAutoSquashBaseTest < Minitest::Test
  def test_auto_squash_base_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::AutoSquashBase < McptaskRunner::ClaudeCodeBase
  end

  def test_workflow_body_omits_code_review
    obj = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 1, task_id: 456)
    steps = obj.send(:workflow_body, start: 3)
    refute_includes steps, 'CODE REVIEW'
    refute_includes steps, '/code-review:code-review'
  end

  def test_workflow_body_derives_step_numbers_from_start
    obj = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 1, task_id: 456)
    # 9 numbered impl steps → CI at start+9, FINAL OUTPUT at start+10
    body3 = obj.send(:workflow_body, start: 3)
    assert_includes body3, '12. CI + AUTO-MERGE'
    assert_includes body3, '13. FINAL OUTPUT'
    body4 = obj.send(:workflow_body, start: 4)
    assert_includes body4, '13. CI + AUTO-MERGE'
    assert_includes body4, '14. FINAL OUTPUT'
  end

  def test_auto_squash_status_options_shared_lines
    obj = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 1, task_id: 456)
    opts = obj.send(:auto_squash_status_options, no_more_tasks: nil)
    %w[success ci_failed merge_failed preexisting_test_errors already_done urgent_bug_pending failure].each do |status|
      assert_includes opts, %("#{status}")
    end
    refute_includes opts, '"no_more_tasks"' # omitted when nil
    refute_includes opts, 'loop continues to next task' # loop_note defaults false
  end

  def test_auto_squash_status_options_no_more_tasks_and_loop_note
    obj = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 1, task_id: 456)
    opts = obj.send(:auto_squash_status_options, no_more_tasks: 'no incomplete tasks in the Story', loop_note: true)
    assert_includes opts, '"no_more_tasks" if no incomplete tasks in the Story'
    assert_includes opts, 'loop continues to next task'
  end
end

class ClaudeCodeStoryAutoSquashTest < Minitest::Test
  def test_story_auto_squash_responds_to_run
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    assert_respond_to story_auto_squash, :run
  end

  def test_story_auto_squash_inherits_from_auto_squash_base
    assert McptaskRunner::ClaudeCode::StoryAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
  end

  def test_story_auto_squash_uses_genius_model
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    assert_equal 'genius', story_auto_squash.send(:model_name)
  end

  def test_story_auto_squash_accepts_edits
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    assert story_auto_squash.send(:accept_edits?)
  end

  def test_story_auto_squash_requires_story_id
    assert_raises(ArgumentError) do
      McptaskRunner::ClaudeCode::StoryAutoSquash.new
    end
  end

  def test_story_auto_squash_instructions_includes_story_id
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 456, task_id: 789)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'Story #456'
    assert_includes instructions, 'mcptask://pieces/jchsoft/456'
  end

  def test_story_auto_squash_instructions_includes_load_story_context_step
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'LOAD STORY'
    assert_includes instructions, 'subtasks'
    assert_includes instructions, 'pre-selected by triage'
    assert_includes instructions, 'mcptask://pieces/jchsoft/123'
  end

  def test_story_auto_squash_instructions_includes_workflow_steps
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, '3. GIT:'
    assert_includes instructions, 'git checkout main'
    assert_includes instructions, 'CREATE BRANCH'
    assert_includes instructions, 'IMPLEMENT TASK'
    assert_includes instructions, 'UNIT TESTS'
    assert_includes instructions, 'SYSTEM TESTS'
    assert_includes instructions, 'PUSH'
    assert_includes instructions, 'CREATE PR'
  end

  def test_story_auto_squash_instructions_includes_auto_merge
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'AUTO-SQUASH'
    assert_includes instructions, 'gh pr merge --squash --delete-branch'
    assert_includes instructions, 'auto-merge'
  end

  def test_story_auto_squash_instructions_includes_ci_retry_logic
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'bin/ci'
    assert_includes instructions, 'CI FAILS'
    assert_includes instructions, 'Retry bin/ci'
    assert_includes instructions, 'Retry fails'
    assert_includes instructions, 'ci_failed'
  end

  def test_story_auto_squash_instructions_includes_wvrunner_result
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 789, task_id: 101)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'story_id'
    assert_includes instructions, '789'
    assert_includes instructions, 'task_id'
  end

  def test_story_auto_squash_instructions_includes_status_values
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'success'
    assert_includes instructions, 'no_more_tasks'
    assert_includes instructions, 'ci_failed'
    assert_includes instructions, 'failure'
  end

  def test_story_auto_squash_instructions_includes_compile_assets_step
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'COMPILE TEST ASSETS'
    assert_includes instructions, 'assets:precompile'
  end

  def test_story_auto_squash_instructions_omits_code_review
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    refute_includes instructions, 'CODE REVIEW'
    refute_includes instructions, '/code-review:code-review'
  end

  def test_story_auto_squash_instructions_uses_test_runner_skill
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'test-runner'
    assert_includes instructions, '/test-runner'
  end

  def test_story_auto_squash_instructions_ci_step_uses_ci_runner_skill
    story_auto_squash = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = story_auto_squash.send(:build_instructions)
    assert_includes instructions, 'ci-runner'
    assert_includes instructions, '/ci-runner'
  end
end

class ClaudeCodeTodayAutoSquashTest < Minitest::Test
  def test_today_auto_squash_responds_to_run
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        assert_respond_to today_auto_squash, :run
      end
    end
  end

  def test_today_auto_squash_inherits_from_auto_squash_base
    assert McptaskRunner::ClaudeCode::TodayAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
  end

  def test_today_auto_squash_uses_genius_model
    today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
    assert_equal 'genius', today_auto_squash.send(:model_name)
  end

  def test_today_auto_squash_accepts_edits
    today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
    assert today_auto_squash.send(:accept_edits?)
  end

  def test_today_auto_squash_instructions_includes_project_id
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'project_relative_id=99'
        assert_includes instructions, 'mcptask://pieces/jchsoft/@next'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_git_checkout_main
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'git checkout main && git pull'
        refute_includes instructions, 'GIT STATE + RESUME CHECK'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_workflow_steps
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'CREATE BRANCH'
        assert_includes instructions, 'IMPLEMENT TASK'
        assert_includes instructions, 'UNIT TESTS'
        assert_includes instructions, 'SYSTEM TESTS'
        assert_includes instructions, 'PUSH'
        assert_includes instructions, 'CREATE PR'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_auto_merge
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'AUTO-SQUASH'
        assert_includes instructions, 'gh pr merge --squash --delete-branch'
        assert_includes instructions, 'auto-merge'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_ci_retry_logic
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'bin/ci'
        assert_includes instructions, 'CI FAILS'
        assert_includes instructions, 'Retry bin/ci'
        assert_includes instructions, 'Retry fails'
        assert_includes instructions, 'ci_failed'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_wvrunner_result
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'TASKRUNNER_RESULT'
        assert_includes instructions, 'status'
        assert_includes instructions, 'PROGRESS LOGGING'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_status_values
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'success'
        assert_includes instructions, 'no_more_tasks'
        assert_includes instructions, 'ci_failed'
        assert_includes instructions, 'failure'
      end
    end
  end

  def test_today_auto_squash_instructions_includes_compile_assets_step
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        assert_includes instructions, 'COMPILE TEST ASSETS'
        assert_includes instructions, 'assets:precompile'
      end
    end
  end

  def test_today_auto_squash_instructions_omits_code_review
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = today_auto_squash.send(:build_instructions)
        refute_includes instructions, 'CODE REVIEW'
        refute_includes instructions, '/code-review:code-review'
      end
    end
  end

  def test_today_auto_squash_raises_when_project_id_not_found
    File.stub :exist?, false do
      today_auto_squash = McptaskRunner::ClaudeCode::TodayAutoSquash.new
      assert_raises(RuntimeError) do
        today_auto_squash.send(:build_instructions)
      end
    end
  end
end

class ClaudeCodeStoryManualTest < Minitest::Test
  def test_story_manual_responds_to_run
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    assert_respond_to story_manual, :run
  end

  def test_story_manual_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::StoryManual < McptaskRunner::ClaudeCodeBase
  end

  def test_story_manual_uses_genius_model
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    assert_equal 'genius', story_manual.send(:model_name)
  end

  def test_story_manual_accepts_edits
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    assert story_manual.send(:accept_edits?)
  end

  def test_story_manual_requires_story_id
    assert_raises(ArgumentError) do
      McptaskRunner::ClaudeCode::StoryManual.new
    end
  end

  def test_story_manual_instructions_includes_story_id
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 456, task_id: 789)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'Story #456'
    assert_includes instructions, 'mcptask://pieces/jchsoft/456'
  end

  def test_story_manual_instructions_includes_load_story_context_step
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'LOAD STORY'
    assert_includes instructions, 'subtasks'
    assert_includes instructions, 'pre-selected by triage'
    assert_includes instructions, 'mcptask://pieces/jchsoft/123'
  end

  def test_story_manual_instructions_includes_load_task_details_step
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'LOAD TASK'
    assert_includes instructions, 'mcptask://pieces/jchsoft/456'
    assert_includes instructions, 'TASKRUNNER_TASK_INFO'
  end

  def test_story_manual_instructions_includes_workflow_steps
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, '3. GIT:'
    assert_includes instructions, 'git checkout main'
    assert_includes instructions, 'CREATE BRANCH'
    assert_includes instructions, 'IMPLEMENT TASK'
    assert_includes instructions, 'UNIT TESTS'
    assert_includes instructions, 'SYSTEM TESTS'
    assert_includes instructions, 'PUSH'
    assert_includes instructions, 'CREATE PR'
  end

  def test_story_manual_instructions_emphasizes_no_merge
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'NO MERGE'
    assert_includes instructions, 'MANUAL'
    assert_includes instructions, 'NOT merged. Human reviews'
    assert_includes instructions, 'Human reviews'
  end

  def test_story_manual_instructions_includes_wvrunner_result
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 789, task_id: 101)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'story_id'
    assert_includes instructions, '789'
    assert_includes instructions, 'task_id'
  end

  def test_story_manual_instructions_includes_status_values
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'success'
    assert_includes instructions, 'no_more_tasks'
    assert_includes instructions, 'failure'
  end

  def test_story_manual_instructions_includes_ci_step
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'LOCAL CI'
    assert_includes instructions, 'bin/ci'
    assert_includes instructions, 'ci-runner'
    refute_includes instructions, 'run_in_background'
    refute_includes instructions, 'poll every 5 minutes'
  end

  def test_story_manual_instructions_uses_test_runner_skill
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'test-runner'
    assert_includes instructions, '/test-runner'
  end

  def test_story_manual_instructions_includes_screenshot_steps
    story_manual = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = story_manual.send(:build_instructions)
    assert_includes instructions, 'SCREENSHOTS'
    assert_includes instructions, 'PR SCREENSHOTS'
    assert_includes instructions, 'pr-screenshot'
  end
end

class ClaudeCodeQueueAutoSquashTest < Minitest::Test
  def test_queue_auto_squash_responds_to_run
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        assert_respond_to queue_auto_squash, :run
      end
    end
  end

  def test_queue_auto_squash_inherits_from_auto_squash_base
    assert McptaskRunner::ClaudeCode::QueueAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
  end

  def test_queue_auto_squash_uses_genius_model
    queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
    assert_equal 'genius', queue_auto_squash.send(:model_name)
  end

  def test_queue_auto_squash_accepts_edits
    queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
    assert queue_auto_squash.send(:accept_edits?)
  end

  def test_queue_auto_squash_instructions_includes_project_id
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'project_relative_id=99'
        assert_includes instructions, 'mcptask://pieces/jchsoft/@next'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_git_checkout_main
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'git checkout main && git pull'
        refute_includes instructions, 'GIT STATE + RESUME CHECK'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_workflow_steps
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'CREATE BRANCH'
        assert_includes instructions, 'IMPLEMENT TASK'
        assert_includes instructions, 'UNIT TESTS'
        assert_includes instructions, 'SYSTEM TESTS'
        assert_includes instructions, 'PUSH'
        assert_includes instructions, 'CREATE PR'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_auto_merge
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'AUTO-SQUASH'
        assert_includes instructions, 'gh pr merge --squash --delete-branch'
        assert_includes instructions, 'auto-merge'
      end
    end
  end

  def test_queue_auto_squash_instructions_mentions_queue_mode
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'QUEUE mode'
        assert_includes instructions, '24/7'
        assert_includes instructions, 'no quota'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_ci_retry_logic
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'bin/ci'
        assert_includes instructions, 'CI FAILS'
        assert_includes instructions, 'Retry bin/ci'
        assert_includes instructions, 'Retry fails'
        assert_includes instructions, 'ci_failed'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_wvrunner_result
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'TASKRUNNER_RESULT'
        assert_includes instructions, 'status'
        assert_includes instructions, 'PROGRESS LOGGING'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_status_values
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'success'
        assert_includes instructions, 'no_more_tasks'
        assert_includes instructions, 'ci_failed'
        assert_includes instructions, 'failure'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_compile_assets_step
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        assert_includes instructions, 'COMPILE TEST ASSETS'
        assert_includes instructions, 'assets:precompile'
      end
    end
  end

  def test_queue_auto_squash_instructions_omits_code_review
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = queue_auto_squash.send(:build_instructions)
        refute_includes instructions, 'CODE REVIEW'
        refute_includes instructions, '/code-review:code-review'
      end
    end
  end

  def test_queue_auto_squash_raises_when_project_id_not_found
    File.stub :exist?, false do
      queue_auto_squash = McptaskRunner::ClaudeCode::QueueAutoSquash.new
      assert_raises(RuntimeError) do
        queue_auto_squash.send(:build_instructions)
      end
    end
  end
end

class ClaudeCodeOnceAutoSquashTest < Minitest::Test
  def test_once_auto_squash_responds_to_run
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        assert_respond_to once_auto_squash, :run
      end
    end
  end

  def test_once_auto_squash_inherits_from_auto_squash_base
    assert McptaskRunner::ClaudeCode::OnceAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
  end

  def test_once_auto_squash_uses_genius_model
    once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
    assert_equal 'genius', once_auto_squash.send(:model_name)
  end

  def test_once_auto_squash_accepts_edits
    once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
    assert once_auto_squash.send(:accept_edits?)
  end

  def test_once_auto_squash_instructions_includes_project_id
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'project_relative_id=99'
        assert_includes instructions, 'mcptask://pieces/jchsoft/@next'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_git_checkout_main
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'git checkout main && git pull'
        refute_includes instructions, 'GIT STATE + RESUME CHECK'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_workflow_steps
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'CREATE BRANCH'
        assert_includes instructions, 'IMPLEMENT TASK'
        assert_includes instructions, 'UNIT TESTS'
        assert_includes instructions, 'SYSTEM TESTS'
        assert_includes instructions, 'PUSH'
        assert_includes instructions, 'CREATE PR'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_auto_merge
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'AUTO-SQUASH'
        assert_includes instructions, 'gh pr merge --squash --delete-branch'
        assert_includes instructions, 'auto-merge'
      end
    end
  end

  def test_once_auto_squash_instructions_mentions_once_mode
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'ONCE mode'
        assert_includes instructions, 'one task, then exit'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_ci_retry_logic
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'bin/ci'
        assert_includes instructions, 'CI FAILS'
        assert_includes instructions, 'Retry bin/ci'
        assert_includes instructions, 'Retry fails'
        assert_includes instructions, 'ci_failed'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_wvrunner_result
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'TASKRUNNER_RESULT'
        assert_includes instructions, 'status'
        assert_includes instructions, 'PROGRESS LOGGING'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_status_values
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'success'
        assert_includes instructions, 'no_more_tasks'
        assert_includes instructions, 'ci_failed'
        assert_includes instructions, 'failure'
      end
    end
  end

  def test_once_auto_squash_instructions_includes_compile_assets_step
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, 'COMPILE TEST ASSETS'
        assert_includes instructions, 'assets:precompile'
      end
    end
  end

  def test_once_auto_squash_instructions_omits_code_review
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        refute_includes instructions, 'CODE REVIEW'
        refute_includes instructions, '/code-review:code-review'
      end
    end
  end

  def test_once_auto_squash_raises_when_project_id_not_found
    File.stub :exist?, false do
      once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
      assert_raises(RuntimeError) do
        once_auto_squash.send(:build_instructions)
      end
    end
  end

  def test_once_auto_squash_instructions_includes_time_management
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        once_auto_squash = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = once_auto_squash.send(:build_instructions)
        assert_includes instructions, '>70 min elapsed'
      end
    end
  end
end

class TimeAwarenessInstructionsTest < Minitest::Test
  def test_today_auto_squash_instructions_includes_time_management
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = obj.send(:build_instructions)
        assert_includes instructions, '>70 min elapsed'
      end
    end
  end

  def test_queue_auto_squash_instructions_includes_time_management
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = obj.send(:build_instructions)
        assert_includes instructions, '>70 min elapsed'
      end
    end
  end

  def test_story_auto_squash_instructions_includes_time_management
    obj = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = obj.send(:build_instructions)
    assert_includes instructions, '>70 min elapsed'
  end

  def test_honest_instructions_includes_time_management
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::Honest.new
        instructions = obj.send(:build_instructions)
        assert_includes instructions, '>70 min elapsed'
      end
    end
  end

  def test_review_instructions_includes_time_management
    obj = McptaskRunner::ClaudeCode::Review.new
    instructions = obj.send(:build_instructions)
    assert_includes instructions, '>70 min elapsed'
  end

  def test_story_manual_instructions_includes_time_management
    obj = McptaskRunner::ClaudeCode::StoryManual.new(story_id: 123, task_id: 456)
    instructions = obj.send(:build_instructions)
    assert_includes instructions, '>70 min elapsed'
  end

  def test_dry_instructions_does_not_include_time_management
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::Dry.new
        instructions = obj.send(:build_instructions)
        refute_includes instructions, '>70 min elapsed'
      end
    end
  end
end

class ClaudeCodeTaskManualTest < Minitest::Test
  def test_task_manual_responds_to_run
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    assert_respond_to task_manual, :run
  end

  def test_task_manual_inherits_from_claude_code_base
    assert McptaskRunner::ClaudeCode::TaskManual < McptaskRunner::ClaudeCodeBase
  end

  def test_task_manual_uses_genius_model
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    assert_equal 'genius', task_manual.send(:model_name)
  end

  def test_task_manual_accepts_edits
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    assert task_manual.send(:accept_edits?)
  end

  def test_task_manual_requires_task_id
    assert_raises(ArgumentError) do
      McptaskRunner::ClaudeCode::TaskManual.new
    end
  end

  def test_task_manual_instructions_includes_task_id
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 456)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'task #456'
    assert_includes instructions, 'mcptask://pieces/jchsoft/456'
  end

  def test_task_manual_instructions_includes_load_task_step
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'LOAD TASK'
    assert_includes instructions, 'TASKRUNNER_TASK_INFO'
  end

  def test_task_manual_instructions_includes_workflow_steps
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'GIT SETUP'
    assert_includes instructions, 'git checkout main'
    assert_includes instructions, 'CREATE BRANCH'
    assert_includes instructions, 'IMPLEMENT TASK'
    assert_includes instructions, 'UNIT TESTS'
    assert_includes instructions, 'SYSTEM TESTS'
    assert_includes instructions, 'PUSH'
    assert_includes instructions, 'CREATE PR'
  end

  def test_task_manual_instructions_uses_resume_step_when_resuming
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123, resuming: true)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'RESUME TASK'
    assert_includes instructions, 'SKIP steps 2-3'
    refute_includes instructions, 'GIT SETUP'
  end

  def test_create_branch_step_checks_for_existing_branch_before_creating
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'git branch --list "*<task_id>*"'
    assert_includes instructions, 'RESUME existing work'
  end

  def test_task_manual_instructions_emphasizes_no_merge
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'NO MERGE'
    assert_includes instructions, 'MANUAL'
    assert_includes instructions, 'NOT merged. Human reviews'
    assert_includes instructions, 'Human reviews'
  end

  def test_task_manual_instructions_includes_wvrunner_result
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 789)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'task_id'
    assert_includes instructions, '789'
  end

  def test_task_manual_instructions_includes_status_values
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'success'
    assert_includes instructions, 'failure'
  end

  def test_task_manual_instructions_includes_ci_step
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'LOCAL CI'
    assert_includes instructions, 'bin/ci'
    assert_includes instructions, 'ci-runner'
  end

  def test_task_manual_instructions_uses_test_runner_skill
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'test-runner'
    assert_includes instructions, '/test-runner'
  end

  def test_task_manual_instructions_includes_screenshot_steps
    task_manual = McptaskRunner::ClaudeCode::TaskManual.new(task_id: 123)
    instructions = task_manual.send(:build_instructions)
    assert_includes instructions, 'SCREENSHOTS'
    assert_includes instructions, 'PR SCREENSHOTS'
    assert_includes instructions, 'pr-screenshot'
  end
end

class ClaudeCodeTaskAutoSquashTest < Minitest::Test
  def test_task_auto_squash_responds_to_run
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    assert_respond_to task_auto_squash, :run
  end

  def test_task_auto_squash_inherits_from_auto_squash_base
    assert McptaskRunner::ClaudeCode::TaskAutoSquash < McptaskRunner::ClaudeCode::AutoSquashBase
  end

  def test_task_auto_squash_uses_genius_model
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    assert_equal 'genius', task_auto_squash.send(:model_name)
  end

  def test_task_auto_squash_accepts_edits
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    assert task_auto_squash.send(:accept_edits?)
  end

  def test_task_auto_squash_requires_task_id
    assert_raises(ArgumentError) do
      McptaskRunner::ClaudeCode::TaskAutoSquash.new
    end
  end

  def test_task_auto_squash_instructions_includes_task_id
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 456)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'task #456'
    assert_includes instructions, 'mcptask://pieces/jchsoft/456'
  end

  def test_task_auto_squash_instructions_includes_workflow_steps
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'GIT SETUP'
    assert_includes instructions, 'git checkout main'
    assert_includes instructions, 'CREATE BRANCH'
    assert_includes instructions, 'IMPLEMENT TASK'
    assert_includes instructions, 'UNIT TESTS'
    assert_includes instructions, 'SYSTEM TESTS'
    assert_includes instructions, 'PUSH'
    assert_includes instructions, 'CREATE PR'
  end

  def test_task_auto_squash_instructions_uses_resume_step_when_resuming
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123, resuming: true)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'RESUME TASK'
    assert_includes instructions, 'SKIP steps 2-3'
    refute_includes instructions, 'GIT SETUP'
  end

  def test_task_auto_squash_instructions_includes_auto_merge
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'AUTO-SQUASH'
    assert_includes instructions, 'gh pr merge --squash --delete-branch'
    assert_includes instructions, 'auto-merge'
  end

  def test_task_auto_squash_instructions_includes_ci_retry_logic
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'bin/ci'
    assert_includes instructions, 'CI FAILS'
    assert_includes instructions, 'Retry bin/ci'
    assert_includes instructions, 'Retry fails'
    assert_includes instructions, 'ci_failed'
  end

  def test_task_auto_squash_instructions_includes_wvrunner_result
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 789)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'TASKRUNNER_RESULT'
    assert_includes instructions, 'task_id'
    assert_includes instructions, '789'
  end

  def test_task_auto_squash_instructions_includes_status_values
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'success'
    assert_includes instructions, 'ci_failed'
    assert_includes instructions, 'failure'
  end

  def test_task_auto_squash_instructions_includes_compile_assets_step
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'COMPILE TEST ASSETS'
    assert_includes instructions, 'assets:precompile'
  end

  def test_task_auto_squash_instructions_omits_code_review
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    refute_includes instructions, 'CODE REVIEW'
    refute_includes instructions, '/code-review:code-review'
  end

  def test_task_auto_squash_instructions_uses_test_runner_skill
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'test-runner'
    assert_includes instructions, '/test-runner'
  end

  def test_task_auto_squash_instructions_ci_step_uses_ci_runner_skill
    task_auto_squash = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = task_auto_squash.send(:build_instructions)
    assert_includes instructions, 'ci-runner'
    assert_includes instructions, '/ci-runner'
  end
end

class PreexistingTestErrorsInstructionsTest < Minitest::Test
  def test_once_auto_squash_includes_preexisting_test_errors_instruction
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::OnceAutoSquash.new
        instructions = obj.send(:build_instructions)
        assert_includes instructions, 'PREEXISTING TEST ERRORS'
        assert_includes instructions, 'CreatePieceTool'
        assert_includes instructions, 'preexisting_test_errors'
      end
    end
  end

  def test_today_auto_squash_includes_preexisting_test_errors_instruction
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::TodayAutoSquash.new
        instructions = obj.send(:build_instructions)
        assert_includes instructions, 'PREEXISTING TEST ERRORS'
        assert_includes instructions, 'CreatePieceTool'
        assert_includes instructions, 'preexisting_test_errors'
      end
    end
  end

  def test_queue_auto_squash_includes_preexisting_test_errors_instruction
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::QueueAutoSquash.new
        instructions = obj.send(:build_instructions)
        assert_includes instructions, 'PREEXISTING TEST ERRORS'
        assert_includes instructions, 'CreatePieceTool'
        assert_includes instructions, 'preexisting_test_errors'
      end
    end
  end

  def test_story_auto_squash_includes_preexisting_test_errors_instruction
    obj = McptaskRunner::ClaudeCode::StoryAutoSquash.new(story_id: 123, task_id: 456)
    instructions = obj.send(:build_instructions)
    assert_includes instructions, 'PREEXISTING TEST ERRORS'
    assert_includes instructions, 'CreatePieceTool'
    assert_includes instructions, 'preexisting_test_errors'
  end

  def test_task_auto_squash_includes_preexisting_test_errors_instruction
    obj = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = obj.send(:build_instructions)
    assert_includes instructions, 'PREEXISTING TEST ERRORS'
    assert_includes instructions, 'CreatePieceTool'
    assert_includes instructions, 'preexisting_test_errors'
  end

  def test_preexisting_instruction_includes_bug_task_creation_details
    obj = McptaskRunner::ClaudeCode::TaskAutoSquash.new(task_id: 123)
    instructions = obj.send(:build_instructions)
    assert_includes instructions, 'task_type_code'
    assert_includes instructions, '"bug"'
    assert_includes instructions, 'priority_code'
    assert_includes instructions, '"urgent"'
    assert_includes instructions, 'project_id'
  end

  def test_dry_does_not_include_preexisting_test_errors_instruction
    File.stub :exist?, true do
      File.stub :read, "project_relative_id=99\naccount_code: `jchsoft`" do
        obj = McptaskRunner::ClaudeCode::Dry.new
        instructions = obj.send(:build_instructions)
        refute_includes instructions, 'PREEXISTING TEST ERRORS'
      end
    end
  end
end
