# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'tmpdir'
require 'fileutils'

class TimeStatusClientTest < Minitest::Test
  Klass = McptaskRunner::TimeStatusClient

  def setup
    @prev_token = ENV.delete('MCPTASK_TOKEN')
    @prev_base = ENV.delete('MCPTASK_BASE_URL')
    @prev_account = ENV.delete('MCPTASK_ACCOUNT')
    # The test_helper kill switch (#10465) blocks real HTTP; lift it for this file
    # because these tests stub Net::HTTP and only exercise parsing/error paths.
    @prev_disable = ENV.delete(McptaskRunner::EventStream::DISABLE_ENV)
    # TimeStatusClient#token_env_name reads the Authorization header out of the cwd's .mcp.json and
    # only falls back to MCPTASK_TOKEN when there is none. Run from an empty dir so these cases
    # depend on the env var they set rather than on whatever token name this host's real .mcp.json
    # happens to interpolate (on a dev machine it is ${WORKVECTOR_KAMR_TOKEN}, and every case here
    # then failed with "MCPTASK token env var not set").
    @orig_dir = Dir.pwd
    @tmpdir = Dir.mktmpdir
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@orig_dir)
    FileUtils.rm_rf(@tmpdir)
    ENV['MCPTASK_TOKEN'] = @prev_token if @prev_token
    ENV['MCPTASK_BASE_URL'] = @prev_base if @prev_base
    ENV['MCPTASK_ACCOUNT'] = @prev_account if @prev_account
    ENV[McptaskRunner::EventStream::DISABLE_ENV] = @prev_disable if @prev_disable
  end

  def test_raises_when_token_missing
    ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
    error = assert_raises(Klass::Error) { Klass.fetch }
    assert_match(/token/i, error.message)
  end

  def test_parses_today_value_and_hour_goal
    ENV['MCPTASK_TOKEN'] = 'fake-token'
    ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
    ENV['MCPTASK_ACCOUNT'] = 'jchsoft'

    body = JSON.generate(
      'today' => { 'value' => 6.4, 'hour_goal' => 8.0, 'state' => 'on_track' },
      'this_week' => { 'value' => 24.0 }
    )

    with_stubbed_http(success_response(body)) do
      result = Klass.fetch
      assert_equal({ worked_today: 6.4, per_day: 8.0 }, result)
    end
  end

  def test_raises_on_non_2xx
    ENV['MCPTASK_TOKEN'] = 'fake-token'
    ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'

    with_stubbed_http(error_response('500')) do
      error = assert_raises(Klass::Error) { Klass.fetch }
      assert_match(/HTTP 500/, error.message)
    end
  end

  def test_raises_on_missing_today_key
    ENV['MCPTASK_TOKEN'] = 'fake-token'
    ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'

    with_stubbed_http(success_response(JSON.generate('this_week' => {}))) do
      error = assert_raises(Klass::Error) { Klass.fetch }
      assert_match(/today/, error.message)
    end
  end

  def test_raises_on_invalid_json
    ENV['MCPTASK_TOKEN'] = 'fake-token'
    ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'

    with_stubbed_http(success_response('not json')) do
      error = assert_raises(Klass::Error) { Klass.fetch }
      assert_match(/JSON/i, error.message)
    end
  end

  private

  def success_response(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.body = body
    response
  end

  def error_response(code)
    klass = Net::HTTPInternalServerError
    response = klass.new('1.1', code, 'Internal Server Error')
    response.instance_variable_set(:@read, true)
    response.body = ''
    response
  end

  def with_stubbed_http(response)
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_req| response }
    Net::HTTP.stub :start, ->(_h, _p, _opts = {}, &block) { block.call(fake_http) } do
      yield
    end
  end
end
