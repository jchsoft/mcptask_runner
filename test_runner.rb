#!/usr/bin/env ruby
# frozen_string_literal: true

puts '🧪 Running all mcptask_runner tests...'
puts '=' * 80

test_files = [
  'test/logger_test.rb',
  'test/railtie_test.rb',
  'test/services/claude_code_base/basics_test.rb',
  'test/services/claude_code_base/parsing_test.rb',
  'test/services/claude_code_base/command_test.rb',
  'test/services/claude_code_base/streaming_test.rb',
  'test/services/claude_code_base/retry_test.rb',
  'test/services/claude_code_base/api_overload_test.rb',
  'test/services/claude_code_base/context_overflow_test.rb',
  'test/services/claude_code_base/kill_process_test.rb',
  'test/services/claude_code_base/tools_test.rb',
  'test/services/claude_code_base/quota_test.rb',
  'test/services/claude_code_base/stall_test.rb',
  'test/services/claude_code_base/heartbeat_test.rb',
  'test/services/claude_code_base/instructions_test.rb',
  'test/services/claude_code_step_tests.rb',
  'test/services/claude_code_test.rb',
  'test/services/claude_code_triage_test.rb',
  'test/services/claude_code/auto_squash_preflight_test.rb',
  'test/services/claude_code/executor_kwarg_plumbing_test.rb',
  'test/services/daily_scheduler_test.rb',
  'test/services/decider_test.rb',
  'test/services/output_formatter_test.rb',
  'test/services/permission_syncer_test.rb',
  'test/services/snapshot_builder_test.rb',
  'test/services/waiting_strategy_test.rb',
  'test/services/work_loop/basics_test.rb',
  'test/services/work_loop/once_test.rb',
  'test/services/work_loop/review_test.rb',
  'test/services/work_loop/story_test.rb',
  'test/services/work_loop/today_auto_squash_test.rb',
  'test/services/work_loop/queue_test.rb',
  'test/services/work_loop/task_test.rb',
  'test/services/work_loop/workflow_test.rb',
  'test/services/work_loop/triage_test.rb',
  'test/tasks_test.rb',
  'test/test_helper_test.rb',
  'test/version_manager_test.rb',
  'test/mcptask_runner_test.rb'
]

total_runs = 0
total_assertions = 0
total_failures = 0
total_errors = 0
failed_files = []

test_files.each do |file|
  next unless File.exist?(file)

  puts "\n📝 #{file}"
  output = `ruby -I lib -I test #{file} 2>&1`
  puts output

  # Parse test results
  if output =~ /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors/
    runs = ::Regexp.last_match(1).to_i
    assertions = ::Regexp.last_match(2).to_i
    failures = ::Regexp.last_match(3).to_i
    errors = ::Regexp.last_match(4).to_i

    total_runs += runs
    total_assertions += assertions
    total_failures += failures
    total_errors += errors

    failed_files << file if failures.positive? || errors.positive?
  end
end

puts "\n" + '=' * 80
puts '📊 TOTAL RESULTS:'
puts "   Runs: #{total_runs}"
puts "   Assertions: #{total_assertions}"
puts "   Failures: #{total_failures}"
puts "   Errors: #{total_errors}"

if failed_files.any?
  puts "\n❌ Failed files:"
  failed_files.each { |f| puts "   - #{f}" }
  exit 1
else
  puts "\n✅ All tests passed!"
  exit 0
end
