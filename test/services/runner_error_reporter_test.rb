# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'tmpdir'
require 'fileutils'

class RunnerErrorReporterTest < Minitest::Test
  Klass = McptaskRunner::RunnerErrorReporter

  def setup
    @prev = {}
    %w[MCPTASK_TOKEN MCPTASK_BASE_URL MCPTASK_ACCOUNT MCPTASK_PROJECT_ID].each do |k|
      @prev[k] = ENV.delete(k)
    end
    @prev_disable = ENV.delete(McptaskRunner::EventStream::DISABLE_ENV)
    @orig_dir = Dir.pwd
    @tmpdir = Dir.mktmpdir
    # Base config: real HTTP "enabled" (DISABLE_ENV unset), token+url present, under jchsoft.
    ENV['MCPTASK_TOKEN'] = 'fake-token'
    ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
    ENV['MCPTASK_ACCOUNT'] = 'jchsoft'
  end

  def teardown
    @prev.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    ENV[McptaskRunner::EventStream::DISABLE_ENV] = @prev_disable if @prev_disable
    Dir.chdir(@orig_dir)
    FileUtils.rm_rf(@tmpdir)
  end

  # --- classification -------------------------------------------------------

  def test_reports_hard_error_into_errors_epic
    in_tmpdir do
      requests = []
      piece_id = with_capturing_http([json_response(201, { 'relative_id' => 500 })], requests) do
        report(status: 'error', termination: 'result', error_message: 'boom')
      end

      assert_equal 500, piece_id
      body = JSON.parse(requests[0].body)
      assert_equal 10_445, body['parent_id']
      assert_equal 69, body['project_id']
      assert_equal 'bug', body['task_type_code']
      assert_equal 'high', body['priority_code']
    end
  end

  def test_reports_loop_crash
    in_tmpdir do
      requests = []
      piece_id = with_capturing_http([json_response(201, { 'relative_id' => 7 })], requests) do
        report(status: 'crash', termination: 'loop_crash', error_message: 'RuntimeError: kaboom')
      end
      assert_equal 7, piece_id
    end
  end

  def test_skips_non_hard_statuses
    in_tmpdir do
      %w[success already_done stalled_for_genius urgent_bug_pending quota_exceeded no_more_tasks].each do |status|
        assert_equal :skipped_not_hard,
                     report(status: status, termination: 'result', error_message: ''),
                     "#{status} must not be reported"
      end
    end
  end

  # --- gates ----------------------------------------------------------------

  def test_skips_when_not_under_jchsoft
    in_tmpdir do
      ENV['MCPTASK_ACCOUNT'] = 'someoneelse'
      assert_equal :skipped_disabled, report(status: 'error', termination: 'result', error_message: 'x')
    end
  end

  def test_skips_when_disabled_env_set
    in_tmpdir do
      ENV[McptaskRunner::EventStream::DISABLE_ENV] = '1'
      assert_equal :skipped_disabled, report(status: 'error', termination: 'result', error_message: 'x')
    end
  end

  def test_skips_when_token_missing
    in_tmpdir do
      ENV.delete('MCPTASK_TOKEN')
      # no .mcp.json in tmpdir → token resolves empty
      assert_equal :skipped_disabled, report(status: 'error', termination: 'result', error_message: 'x')
    end
  end

  # --- throttle -------------------------------------------------------------

  def test_throttles_duplicate_fingerprint
    in_tmpdir do
      responses = [json_response(201, { 'relative_id' => 1 }),
                   json_response(201, { 'relative_id' => 2 })]
      first = second = nil
      with_stubbed_http(responses) do
        first  = report(status: 'error', termination: 'inactivity_kill', error_message: 'inactive for 300s')
        second = report(status: 'error', termination: 'inactivity_kill', error_message: 'inactive for 999s')
      end
      assert_equal 1, first
      assert_equal :throttled, second, 'same normalized fingerprint within window must be throttled'
    end
  end

  def test_distinct_fingerprints_both_report
    in_tmpdir do
      responses = [json_response(201, { 'relative_id' => 1 }),
                   json_response(201, { 'relative_id' => 2 })]
      with_stubbed_http(responses) do
        assert_equal 1, report(status: 'error', termination: 'inactivity_kill', error_message: 'a', task_id: 10)
        assert_equal 2, report(status: 'error', termination: 'context_overflow', error_message: 'b', task_id: 11)
      end
    end
  end

  private

  def report(status:, termination:, error_message:, task_id: nil)
    McptaskRunner::Logger.stub(:latest_run_log, nil) do
      Klass.maybe_report(status: status, termination: termination, error_message: error_message,
                         context: { project_name: 'proj', task_id: task_id, mode: 'test' })
    end
  end

  def in_tmpdir
    Dir.chdir(@tmpdir) { yield }
  end

  def json_response(code, data)
    klass = code == 201 ? Net::HTTPCreated : Net::HTTPOK
    resp = klass.new('1.1', code.to_s, code == 201 ? 'Created' : 'OK')
    resp.instance_variable_set(:@read, true)
    resp.body = JSON.generate(data)
    resp
  end

  def with_stubbed_http(responses)
    call_count = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |_req|
      resp = responses[call_count] || responses.last
      call_count += 1
      resp
    end
    Net::HTTP.stub :start, ->(*_args, **_opts, &block) { block.call(fake_http) } do
      yield
    end
  end

  def with_capturing_http(responses, requests_out)
    call_count = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |req|
      requests_out << req
      resp = responses[call_count] || responses.last
      call_count += 1
      resp
    end
    result = nil
    Net::HTTP.stub :start, ->(*_args, **_opts, &block) { block.call(fake_http) } do
      result = yield
    end
    result
  end
end
