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

# Hard kill switch — even if a token leaks back into ENV during a test run (test forgets
# to clean up, subshell re-exports, .mcp.json grows a literal bearer), this flag forces
# EventStream / TimeStatusClient / ClaudeCodeBase#execute_with_streaming to refuse real
# network I/O. Bug #10465: real runner cards appeared on mcptask.online from test runs.
ENV[McptaskRunner::EventStream::DISABLE_ENV] = "1"

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

# Quota is REST-only (QuotaGuard → TimeStatusClient). The kill switch above makes the
# live REST fetch raise, which fails CLOSED (= quota exceeded). Without a default, every
# normal-flow test would stop at the quota gate. Stub QuotaGuard.status (NOT the underlying
# TimeStatusClient.fetch — that stays real so time_status_client_test / test_isolation_test
# keep exercising it) to an under-quota verdict. Tests needing a specific quota wrap their
# body in `stub_quota(...)` from QuotaTestHelper.
module DefaultQuotaTestStub
  def before_setup
    super
    McptaskRunner::QuotaGuard.define_singleton_method(:status) do
      McptaskRunner::QuotaGuard::Status.new(exceeded: false, worked_today: 0.0, per_day: 8.0, rest_ok: true)
    end
  end
end
Minitest::Test.prepend(DefaultQuotaTestStub)

# Helper to drive the REST quota verdict in a test. Stubs QuotaGuard.status for the block.
# Pass worked/per_day (exceeded derived), or rest_ok: false to exercise the fail-closed path.
module QuotaTestHelper
  def stub_quota(worked: 0.0, per_day: 8.0, rest_ok: true, exceeded: nil, &block)
    exceeded = (!rest_ok || !per_day.positive? || worked >= per_day) if exceeded.nil?
    status = McptaskRunner::QuotaGuard::Status.new(
      exceeded: exceeded, worked_today: worked, per_day: per_day, rest_ok: rest_ok
    )
    McptaskRunner::QuotaGuard.stub(:status, status, &block)
  end
end
