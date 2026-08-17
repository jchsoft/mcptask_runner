# This gem is superseded by mcptask-rails-runner, which ships the Go runner.
#
# Printed here rather than on require, and only when one of these tasks is what
# was actually asked for: Rails loads every railtie's rake file for `db:migrate`
# too, and the conformance suite drives WorkLoop directly without going near
# rake. On stderr, so nothing parsing stdout has to know about it.
#
# top_level_tasks is populated by Rake's init, which runs before the rake files
# are loaded, so this reads the command that was actually typed.
if defined?(Rake) && Rake.application.top_level_tasks.grep(/\Amcptask_runner:/).any?
  warn <<~NOTICE
    [McptaskRunner] This gem is retired. The Go runner is the runner now: it does
    [McptaskRunner] everything this does, runs on Linux and Windows as well, and keeps
    [McptaskRunner] bundler out of the scheduled job's path. Only critical fixes land
    [McptaskRunner] here from now on.
    [McptaskRunner]
    [McptaskRunner]   -  gem "mcptask_runner", git: "git@github.com:jchsoft/mcptask_runner.git"
    [McptaskRunner]   +  gem "mcptask-rails-runner"
    [McptaskRunner]
    [McptaskRunner] Then `bundle install` and `FORCE=1 bundle exec rake mcptask_runner:install`.
    [McptaskRunner] Every rake task keeps its name; config/mcptask_runner.yml, .mcp.json
    [McptaskRunner] and .claude/ are read as they are.
  NOTICE
end

namespace :mcptask_runner do
  desc 'Report a bug: prompts for title/description, creates bug piece on mcptask.online with run log attached'
  task bug_report: :environment do
    require 'mcptask_runner/services/bug_reporter'
    McptaskRunner::BugReporter.call
  end

  namespace :manual do
    MODES = %i[once once_dry today daily review reviews workflow queue].freeze

    MODES.each do |mode|
      desc case mode
           when :once
             'Run a single task once (pass verbose=true for verbose output, default: normal mode)'
           when :once_dry
             'Load and display next task information (dry-run, no execution) (pass verbose=true for verbose output, default: normal mode)'
           when :today
             'Run tasks until end of today (pass verbose=true for verbose output, default: normal mode)'
           when :daily
             'Run tasks continuously in a daily loop (pass verbose=true for verbose output, default: normal mode)'
           when :review
             'Handle PR review feedback on current branch (pass verbose=true for verbose output, default: normal mode)'
           when :reviews
             'Find and process all PRs with unaddressed reviews (pass verbose=true for verbose output, default: normal mode)'
           when :workflow
             'Run full workflow: process reviews first, then tasks for today (pass verbose=true for verbose output, default: normal mode)'
           when :queue
             'Process queue continuously, PRs stay open for review (pass verbose=true for verbose output, ignore_quota=true to skip quota checks)'
      end
      task mode => :environment do
        run_mcptask_runner_task(mode)
      end
    end

    desc 'Process all tasks in a Story, create PRs but leave them open for review (pass story_id as argument)'
    task :story, [:story_id] => :environment do |_t, args|
      story_id = args[:story_id]&.to_i
      raise ArgumentError, 'story_id is required. Usage: rake mcptask_runner:manual:story[123]' unless story_id&.positive?

      run_mcptask_runner_story_task(story_id)
    end

    desc 'Run a specific task by ID, create PR but leave it open for review (pass task_id as argument)'
    task :task, [:task_id] => :environment do |_t, args|
      task_id = args[:task_id]&.to_i
      raise ArgumentError, 'task_id is required. Usage: rake mcptask_runner:manual:task[123]' unless task_id&.positive?

      run_mcptask_runner_task_manual(task_id)
    end
  end

  namespace :prepare do
    desc 'Merge mcptask_runner baseline permissions into this project\'s .claude/settings.local.json'
    task permissions: :environment do
      syncer = McptaskRunner::PermissionSyncer.sync(target_dir: Dir.pwd)
      puts syncer.report
    end
  end

  desc 'Install bundled Claude Code skills and generate a macOS LaunchAgent for weekday scheduling (set FORCE=1 to overwrite existing files)'
  task install: :environment do
    require 'mcptask_runner/services/installer'
    McptaskRunner::Installer.call
  end

  desc 'Refresh bundled skills after gem update — syncs gem skills into .claude/skills/, preserving local edits (set FORCE=1 to overwrite conflicts)'
  task update: :environment do
    require 'mcptask_runner/services/updater'
    McptaskRunner::Updater.call
  end

  namespace :auto do
    desc 'Run a single task once with automatic PR squash-merge after CI passes'
    task once: :environment do
      run_mcptask_runner_auto_once_task
    end

    namespace :squash do
      desc 'Run tasks until quota reached with automatic PR squash-merge after CI passes'
      task today: :environment do
        run_mcptask_runner_auto_squash_today_task
      end

      desc 'Process all tasks in a Story with automatic PR squash-merge after CI passes'
      task :story, [:story_id] => :environment do |_t, args|
        story_id = args[:story_id]&.to_i
        raise ArgumentError, 'story_id is required. Usage: rake mcptask_runner:auto:squash:story[123]' unless story_id&.positive?

        run_mcptask_runner_auto_squash_story_task(story_id)
      end

      desc 'Run a specific task by ID with automatic PR squash-merge after CI passes (pass task_id as argument)'
      task :task, [:task_id] => :environment do |_t, args|
        task_id = args[:task_id]&.to_i
        raise ArgumentError, 'task_id is required. Usage: rake mcptask_runner:auto:squash:task[123]' unless task_id&.positive?

        run_mcptask_runner_auto_squash_task(task_id)
      end

      desc 'Process queue continuously with automatic PR squash-merge after CI passes (pass ignore_quota=true to skip quota checks)'
      task queue: :environment do
        run_mcptask_runner_auto_squash_queue_task
      end
    end
  end

  private

  def run_mcptask_runner_task(mode)
    display_version_info
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    # Map :queue to :queue_manual for namespace :manual
    execute_mode = mode == :queue ? :queue_manual : mode
    McptaskRunner::WorkLoop.new(verbose: verbose, ignore_quota: ignore_quota).execute(execute_mode)
  end

  def run_mcptask_runner_story_task(story_id)
    display_version_info
    puts "[McptaskRunner] Story ID: #{story_id}"
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, story_id: story_id, ignore_quota: ignore_quota).execute(:story_manual)
  end

  def run_mcptask_runner_auto_squash_story_task(story_id)
    display_version_info
    puts "[McptaskRunner] Story ID: #{story_id} (AUTO-SQUASH mode)"
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, story_id: story_id, ignore_quota: ignore_quota).execute(:story_auto_squash)
  end

  def run_mcptask_runner_task_manual(task_id)
    display_version_info
    puts "[McptaskRunner] Task ID: #{task_id}"
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, task_id: task_id, ignore_quota: ignore_quota).execute(:task_manual)
  end

  def run_mcptask_runner_auto_squash_task(task_id)
    display_version_info
    puts "[McptaskRunner] Task ID: #{task_id} (AUTO-SQUASH mode)"
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, task_id: task_id, ignore_quota: ignore_quota).execute(:task_auto_squash)
  end

  def run_mcptask_runner_auto_once_task
    display_version_info
    puts '[McptaskRunner] AUTO-ONCE mode - single task will be automatically merged after CI passes'
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, ignore_quota: ignore_quota).execute(:once_auto_squash)
  end

  def run_mcptask_runner_auto_squash_today_task
    display_version_info
    puts '[McptaskRunner] AUTO-SQUASH TODAY mode - PRs will be automatically merged after CI passes'
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, ignore_quota: ignore_quota).execute(:today_auto_squash)
  end

  def run_mcptask_runner_auto_squash_queue_task
    display_version_info
    puts '[McptaskRunner] AUTO-SQUASH QUEUE mode - processing queue'
    puts '[McptaskRunner] PRs will be automatically merged after CI passes'
    verbose = verbose_mode_enabled?
    ignore_quota = ignore_quota_enabled?
    display_output_mode(verbose)
    display_quota_mode(ignore_quota)
    McptaskRunner::WorkLoop.new(verbose: verbose, ignore_quota: ignore_quota).execute(:queue_auto_squash)
  end

  def verbose_mode_enabled?
    ENV['verbose']&.downcase == 'true'
  end

  def ignore_quota_enabled?
    ENV['ignore_quota']&.downcase == 'true'
  end

  def display_version_info
    puts '=' * 80
    puts "[McptaskRunner] Version: #{McptaskRunner::VERSION}"
    puts "[McptaskRunner] #{McptaskRunner::ClaudeCodeBase.model_source_description}"
    puts "[McptaskRunner] #{McptaskRunner::ClaudeCodeBase.launcher_source_description}"
    puts "[McptaskRunner] #{McptaskRunner::ClaudeCodeBase.bug_destination_source_description}"
    puts "[McptaskRunner] #{McptaskRunner::ClaudeCodeBase.waiting_strategy_source_description}"
    puts '=' * 80
  end

  def display_output_mode(verbose)
    mode = verbose ? 'VERBOSE' : 'NORMAL'
    puts "[McptaskRunner] Output mode: #{mode}"
  end

  def display_quota_mode(ignore_quota)
    return unless ignore_quota

    puts '[McptaskRunner] Quota checking: DISABLED (ignore_quota=true)'
  end
end
