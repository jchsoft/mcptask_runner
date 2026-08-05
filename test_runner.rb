#!/usr/bin/env ruby
# frozen_string_literal: true

puts '🧪 Running all mcptask_runner tests...'
puts '=' * 80

# Discovered, never listed. This used to be a hardcoded roster, and it silently ran 41 of the 64
# test files present — the 23 it skipped included BugReporter, RunnerErrorReporter, EventStream and
# TokenProvisioner, so a piece-creation client that 404s in production, a client whose token env var
# never resolved, and a test file that could not even load all sat behind a green suite. A stale
# entry for a deleted file went unnoticed for the same reason. Globbing means a new test file is
# covered the moment it lands.
test_files = Dir.glob("test/**/*_test.rb").sort

total_runs = 0
total_assertions = 0
total_failures = 0
total_errors = 0
failed_files = []

test_files.each do |file|
  puts "\n📝 #{file}"
  output = `ruby -I lib -I test #{file} 2>&1`.force_encoding('UTF-8')
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
