require "test_helper"

class TasksTest < Minitest::Test
  def test_rake_file_exists
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    assert File.exist?(rake_file)
  end

  def test_rake_file_is_valid_ruby_syntax
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    # Verify it contains namespace definition
    assert content.include?("namespace :mcptask_runner do")
  end

  def test_rake_file_defines_manual_namespace
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("namespace :manual do"), "Should define manual namespace"
  end

  def test_rake_file_defines_auto_squash_namespace
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("namespace :auto do"), "Should define auto namespace"
    assert content.include?("namespace :squash do"), "Should define squash namespace inside auto"
  end

  def test_rake_file_defines_run_once_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("MODES = %i[once once_dry today daily review reviews workflow queue]")
    assert content.include?(".execute("), "Should call execute method"
  end

  def test_rake_file_defines_run_once_dry_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("MODES = %i[once once_dry today daily review reviews workflow queue]")
    assert content.include?("dry-run")
  end

  def test_rake_file_defines_run_today_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("MODES = %i[once once_dry today daily review reviews workflow queue]")
    assert content.include?("end of today")
  end

  def test_rake_file_defines_run_daily_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("MODES = %i[once once_dry today daily review reviews workflow queue]")
    assert content.include?("daily loop")
  end

  def test_rake_file_defines_review_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("MODES = %i[once once_dry today daily review reviews workflow queue]")
    assert content.include?("PR review feedback")
  end

  def test_all_tasks_require_environment
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    # Tasks require :environment for Rails context (dynamically generated via MODES.each)
    assert content.include?("=> :environment")
    assert content.include?("MODES.each")
  end

  def test_all_tasks_have_descriptions
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    # Tasks have descriptions defined via case statement
    assert content.include?("desc case mode")
    assert_equal 8, content.scan(/when :(\w+)/).length, "Should have 8 mode descriptions"
  end

  def test_rake_file_defines_manual_workflow_story_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("task :story"), "Should define story task"
    assert content.include?("[:story_id]"), "Story task should accept story_id argument"
  end

  def test_rake_file_defines_story_task_description
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("Process all tasks in a Story"), "Should have story task description"
    assert content.include?("leave them open for review"), "Should mention leaving PRs open"
  end

  def test_rake_file_story_task_validates_story_id
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("story_id is required"), "Should validate story_id presence"
    assert content.include?("story_id&.positive?"), "Should validate story_id is positive"
  end

  def test_rake_file_story_task_calls_story_helper
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("run_mcptask_runner_story_task"), "Should call story task helper"
    assert content.include?("execute(:story_manual)"), "Should execute story_manual mode"
  end

  # Tests for auto:squash:story task
  def test_rake_file_defines_auto_squash_story_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("namespace :auto do"), "Should define auto namespace"
    assert content.include?("namespace :squash do"), "Should define squash namespace inside auto"
    assert content.include?("task :story"), "Should define story task inside auto:squash"
  end

  def test_rake_file_defines_auto_squash_story_task_description
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("automatic PR squash-merge"), "Should have auto-squash task description"
    assert content.include?("after CI passes"), "Should mention CI passing"
  end

  def test_rake_file_auto_squash_story_task_validates_story_id
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("mcptask_runner:auto:squash:story[123]"), "Should have usage example with story_id"
  end

  def test_rake_file_auto_squash_story_task_calls_helper
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("run_mcptask_runner_auto_squash_story_task"), "Should call auto-squash story task helper"
    assert content.include?("execute(:story_auto_squash)"), "Should execute story_auto_squash mode"
  end

  # Tests for auto:squash:today task
  def test_rake_file_defines_auto_squash_today_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("task today: :environment"), "Should define today task inside auto:squash"
  end

  def test_rake_file_defines_auto_squash_today_task_description
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("Run tasks until quota reached with automatic PR squash-merge"), "Should have auto-squash today task description"
  end

  def test_rake_file_auto_squash_today_task_calls_helper
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("run_mcptask_runner_auto_squash_today_task"), "Should call auto-squash today task helper"
    assert content.include?("execute(:today_auto_squash)"), "Should execute today_auto_squash mode"
  end

  # Tests for auto:squash:queue task
  def test_rake_file_defines_auto_squash_queue_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("task queue: :environment"), "Should define queue task inside auto:squash"
  end

  def test_rake_file_defines_auto_squash_queue_task_description
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("Process queue continuously"), "Should mention continuous processing"
    assert content.include?("ignore_quota"), "Should mention ignore_quota option"
  end

  def test_rake_file_auto_squash_queue_task_calls_helper
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("run_mcptask_runner_auto_squash_queue_task"), "Should call auto-squash queue task helper"
    assert content.include?("execute(:queue_auto_squash)"), "Should execute queue_auto_squash mode"
  end

  # Tests for auto:once task
  def test_rake_file_defines_auto_once_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("task once: :environment"), "Should define once task inside auto namespace"
  end

  def test_rake_file_defines_auto_once_task_description
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("Run a single task once with automatic PR squash-merge"), "Should have auto:once task description"
  end

  def test_rake_file_auto_once_task_calls_helper
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("run_mcptask_runner_auto_once_task"), "Should call auto-once task helper"
    assert content.include?("execute(:once_auto_squash)"), "Should execute once_auto_squash mode"
  end

  def test_rake_file_supports_ignore_quota_env
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("ignore_quota_enabled?"), "Should have ignore_quota helper method"
    assert content.include?("ignore_quota:"), "Should pass ignore_quota to WorkLoop"
  end

  def test_rake_file_defines_bug_report_task
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("task bug_report"), "Should define bug_report task"
    assert content.include?("BugReporter.call"), "Should call BugReporter.call"
  end

  def test_rake_file_bug_report_task_has_description
    rake_file = File.join(File.dirname(__FILE__), "..", "lib", "tasks", "mcptask_runner.rake")
    content = File.read(rake_file)

    assert content.include?("bug piece"), "bug_report task should mention bug piece in description"
  end
end
