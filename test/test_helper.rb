require "minitest/autorun"
begin
  require "minitest/mock"
rescue LoadError
  gem "minitest-mock"
  require "minitest/mock"
end
require "active_support"
require "active_support/core_ext/time"
require "active_support/core_ext/numeric/time"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "mcptask_runner"

# Prevent tests from accidentally opening a real WebSocket to mcptask.online when the
# developer shell has any of these tokens exported. Real emits require an explicit
# start_session. Scrub every env var referenced from `.mcp.json` Authorization headers
# so EventStream / TimeStatusClient resolve to empty token and skip network I/O.
ENV.delete("MCPT_RUNNER_CABLE_URL")
%w[MCPTASK_TOKEN WORKVECTOR_KAMR_TOKEN LLMMN_TOKEN].each { |k| ENV.delete(k) }

# Wipe any stale urgent-bug pin file from previous test runs (pin lives in cwd-relative tmp dir;
# tests sharing the project root would otherwise leak pin state between cases).
module UrgentBugPinTestCleanup
  PIN_RELATIVE = File.join("tmp", "mcptask_runner", "urgent_pin.txt").freeze

  def before_setup
    super
    pin = File.join(Dir.pwd, PIN_RELATIVE)
    File.delete(pin) if File.exist?(pin)
  end
end
Minitest::Test.prepend(UrgentBugPinTestCleanup)
