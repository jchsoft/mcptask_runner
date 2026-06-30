# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'stringio'
require 'tmpdir'
require 'fileutils'

class BugReporterTest < Minitest::Test
  Klass = McptaskRunner::BugReporter

  def setup
    @prev_token     = ENV.delete('MCPTASK_TOKEN')
    @prev_base      = ENV.delete('MCPTASK_BASE_URL')
    @prev_account   = ENV.delete('MCPTASK_ACCOUNT')
    @prev_project   = ENV.delete('MCPTASK_PROJECT_ID')
    @prev_disable   = ENV.delete(McptaskRunner::EventStream::DISABLE_ENV)
    @prev_stdin     = $stdin
    @orig_dir       = Dir.pwd
    # Run all service-calling tests in a tmpdir so .mcp.json is absent and
    # MCPTASK_TOKEN / MCPTASK_BASE_URL env vars are the sole config source.
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    ENV['MCPTASK_TOKEN']     = @prev_token   if @prev_token
    ENV['MCPTASK_BASE_URL']  = @prev_base    if @prev_base
    ENV['MCPTASK_ACCOUNT']   = @prev_account if @prev_account
    ENV['MCPTASK_PROJECT_ID'] = @prev_project if @prev_project
    ENV[McptaskRunner::EventStream::DISABLE_ENV] = @prev_disable if @prev_disable
    $stdin = @prev_stdin
    Dir.chdir(@orig_dir)
    FileUtils.rm_rf(@tmpdir)
  end

  def test_raises_when_disabled_env_set
    in_tmpdir do
      ENV[McptaskRunner::EventStream::DISABLE_ENV] = '1'
      ENV['MCPTASK_TOKEN'] = 'tok'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'

      assert_raises(Klass::Error) { Klass.call }
    end
  end

  def test_raises_when_token_missing
    in_tmpdir do
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      # no token set, no .mcp.json

      error = assert_raises(Klass::Error) { Klass.call }
      assert_match(/token/i, error.message)
    end
  end

  def test_raises_when_base_url_missing
    in_tmpdir do
      ENV['MCPTASK_TOKEN'] = 'fake-token'
      # no base URL set, no .mcp.json

      error = assert_raises(Klass::Error) { Klass.call }
      assert_match(/base URL/i, error.message)
    end
  end

  def test_creates_piece_with_user_input
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'

      $stdin = StringIO.new("Runner crashes on startup\nSomething is broken\n\n")

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 777 } })

      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_stubbed_http([create_resp]) do
          assert_output(/Created piece #777/) { Klass.call }
        end
      end
    end
  end

  def test_attaches_latest_run_log
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'

      $stdin = StringIO.new("Title\nDesc\n\n")

      log_path = File.join(@tmpdir, 'log', 'mcptask_runner_20260601_080000.log')
      FileUtils.mkdir_p(File.join(@tmpdir, 'log'))
      File.write(log_path, 'log content here')

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 42 } })
      attach_resp = json_response(200, { 'success' => true })

      captured_bodies = []
      McptaskRunner::Logger.stub(:latest_run_log, log_path) do
        with_capturing_http([create_resp, attach_resp], captured_bodies) do
          assert_output(/Attaching run log/) { Klass.call }
        end
      end

      attach_body = JSON.parse(captured_bodies[1])
      assert_equal 'mcptask_runner_20260601_080000.log', attach_body.dig('attachment', 'file_name')
      decoded = Base64.decode64(attach_body.dig('attachment', 'file_content'))
      assert_equal 'log content here', decoded
    end
  end

  def test_latest_run_log_skipped_when_nil
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'

      $stdin = StringIO.new("Title\nDesc\n\n")

      responses = [json_response(201, { 'piece' => { 'relative_id' => 5 } })]

      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_stubbed_http(responses) do
          assert_output(/No run log found/) { Klass.call }
        end
      end
    end
  end

  def test_redacts_bearer_tokens
    reporter = Klass.new
    input = '{"headers": {"Authorization": "Bearer supersecrettoken123456"}}'
    result = reporter.send(:redact_tokens, input)
    refute_includes result, 'supersecrettoken123456'
    assert_includes result, '[REDACTED]'
  end

  def test_redacts_authorization_header_value
    reporter = Klass.new
    input = '"Authorization": "Bearer abc123xyz789abc123"'
    result = reporter.send(:redact_tokens, input)
    refute_includes result, 'abc123xyz789abc123'
    assert_includes result, '[REDACTED]'
  end

  def test_short_values_not_redacted
    reporter = Klass.new
    input = '"Authorization": "abc"'
    result = reporter.send(:redact_tokens, input)
    assert_equal input, result
  end

  def test_env_config_attached_when_present
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'

      $stdin = StringIO.new("Title\nDesc\n\n")

      mcp_json_path = File.join(@tmpdir, '.mcp.json')
      File.write(mcp_json_path, '{"mcpServers": {}}')

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 10 } })
      attach_resp = json_response(200, { 'success' => true })

      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_stubbed_http([create_resp, attach_resp]) do
          assert_output(/Attaching config: .mcp.json/) { Klass.call }
        end
      end
    end
  end

  # --- bug destination config (parent_id) ---

  def test_creates_piece_at_project_root_when_no_destination_configured
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'
      ENV.delete(Klass::BUG_PARENT_ENV)

      $stdin = StringIO.new("Title\nDesc\n\n")

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 100 } })

      captured_bodies = []
      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_capturing_http([create_resp], captured_bodies) do
          capture_io { Klass.call }
        end
      end

      create_body = JSON.parse(captured_bodies[0])
      refute create_body.dig('piece', 'parent_id'), 'parent_id must be absent when no destination is configured'
    end
  end

  def test_creates_piece_in_epic_when_config_present
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'
      ENV.delete(Klass::BUG_PARENT_ENV)

      write_bug_destination_config("epic_relative_id: 99999\nepic_name: Auto-bugs\n")

      $stdin = StringIO.new("Title\nDesc\n\n")

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 101 } })

      captured_bodies = []
      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_capturing_http([create_resp], captured_bodies) do
          capture_io { Klass.call }
        end
      end

      create_body = JSON.parse(captured_bodies[0])
      assert_equal 99_999, create_body.dig('piece', 'parent_id')
    end
  end

  def test_env_var_overrides_config_file
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'
      ENV[Klass::BUG_PARENT_ENV] = '88888'

      write_bug_destination_config("epic_relative_id: 99999\n")

      $stdin = StringIO.new("Title\nDesc\n\n")

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 102 } })

      captured_bodies = []
      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_capturing_http([create_resp], captured_bodies) do
          capture_io { Klass.call }
        end
      end

      create_body = JSON.parse(captured_bodies[0])
      assert_equal 88_888, create_body.dig('piece', 'parent_id'), 'env var must override config file'
    end
  end

  def test_invalid_env_var_falls_back_to_config
    in_tmpdir do
      ENV['MCPTASK_TOKEN']    = 'fake-token'
      ENV['MCPTASK_BASE_URL'] = 'https://mcptask.online'
      ENV['MCPTASK_ACCOUNT']  = 'testacct'
      ENV[Klass::BUG_PARENT_ENV] = 'not-a-number'

      write_bug_destination_config("epic_relative_id: 12345\n")

      $stdin = StringIO.new("Title\nDesc\n\n")

      create_resp = json_response(201, { 'piece' => { 'relative_id' => 103 } })

      captured_bodies = []
      McptaskRunner::Logger.stub(:latest_run_log, nil) do
        with_capturing_http([create_resp], captured_bodies) do
          capture_io { Klass.call }
        end
      end

      create_body = JSON.parse(captured_bodies[0])
      assert_equal 12_345, create_body.dig('piece', 'parent_id')
    end
  end

  def write_bug_destination_config(yaml)
    dir = File.join(@tmpdir, 'config')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'bug_destination.yml'), yaml)
  end

  private

  def in_tmpdir
    Dir.chdir(@tmpdir) { yield }
  end

  def json_response(code, data)
    status_map = { 200 => 'OK', 201 => 'Created' }
    klass = code == 201 ? Net::HTTPCreated : Net::HTTPOK
    resp = klass.new('1.1', code.to_s, status_map[code])
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

  def with_capturing_http(responses, bodies_out)
    call_count = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |req|
      bodies_out << req.body
      resp = responses[call_count] || responses.last
      call_count += 1
      resp
    end
    Net::HTTP.stub :start, ->(*_args, **_opts, &block) { block.call(fake_http) } do
      yield
    end
  end
end
