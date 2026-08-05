# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
# Installer lazy-requires this (installer.rb:96) rather than mcptask_runner.rb loading it eagerly,
# so the constant does not exist just from requiring test_helper.
require 'mcptask_runner/services/token_provisioner'

class TokenProvisionerTest < Minitest::Test
  Klass = McptaskRunner::TokenProvisioner

  FAKE_SERVICES = [
    {
      env_var:   'TEST_TOKEN_A',
      filename:  'test_token_a',
      url:       'https://example.com/api/sessions',
      email_env: 'TEST_EMAIL_A',
      pass_env:  'TEST_PASS_A',
      label:     'example.com'
    }
  ].freeze

  def setup
    @tmpdir  = Dir.mktmpdir('token_provisioner_test')
    @env_dir = File.join(@tmpdir, 'mcptask_env.d')
    @zshrc   = File.join(@tmpdir, '.zshrc')
    @home    = @tmpdir

    @prev_email = ENV.delete('TEST_EMAIL_A')
    @prev_pass  = ENV.delete('TEST_PASS_A')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
    ENV['TEST_EMAIL_A'] = @prev_email if @prev_email
    ENV['TEST_PASS_A']  = @prev_pass  if @prev_pass
  end

  def build(opts = {})
    Klass.new(env_dir: @env_dir, zshrc: @zshrc, services: FAKE_SERVICES, home: @home, **opts)
  end

  # --- configure_zshrc ---

  def test_configure_zshrc_adds_sourcing_when_missing
    File.write(@zshrc, "export FOO=bar\n")
    capture_io { build.call }
    assert_match @env_dir, File.read(@zshrc)
  end

  def test_configure_zshrc_idempotent_when_already_present
    File.write(@zshrc, "for file in #{@env_dir}/*; do\n  [ -f \"$file\" ] && source \"$file\"\ndone\n")
    original = File.read(@zshrc)
    capture_io { build.call }
    assert_equal original, File.read(@zshrc)
  end

  def test_configure_zshrc_skips_when_no_zshrc
    # @zshrc does not exist — should not raise
    out, = capture_io { build.call }
    assert_match 'not found', out
  end

  def test_configure_zshrc_creates_env_dir
    File.write(@zshrc, "# empty\n")
    capture_io { build.call }
    assert File.directory?(@env_dir)
  end

  # --- token provisioning ---

  def test_skips_token_when_no_credentials
    File.write(@zshrc, "# empty\n")
    out, = capture_io { build.call }
    assert_match 'Skipping TEST_TOKEN_A', out
    refute File.exist?(File.join(@env_dir, 'test_token_a'))
  end

  def test_writes_token_file_when_credentials_provided
    File.write(@zshrc, "# empty\n")
    ENV['TEST_EMAIL_A'] = 'user@example.com'
    ENV['TEST_PASS_A']  = 'secret'

    response = fake_response('200', '{"token":"jwt_abc123"}')

    Net::HTTP.stub(:new, mock_http(response)) do
      capture_io { build.call }
    end

    token_file = File.join(@env_dir, 'test_token_a')
    assert File.exist?(token_file)
    assert_equal "export TEST_TOKEN_A=\"jwt_abc123\"\n", File.read(token_file)
  end

  def test_token_file_has_restricted_permissions
    File.write(@zshrc, "# empty\n")
    ENV['TEST_EMAIL_A'] = 'user@example.com'
    ENV['TEST_PASS_A']  = 'secret'

    response = fake_response('200', '{"token":"jwt_abc123"}')

    Net::HTTP.stub(:new, mock_http(response)) do
      capture_io { build.call }
    end

    token_file = File.join(@env_dir, 'test_token_a')
    mode = File.stat(token_file).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_warns_when_fetch_fails
    File.write(@zshrc, "# empty\n")
    ENV['TEST_EMAIL_A'] = 'user@example.com'
    ENV['TEST_PASS_A']  = 'secret'

    response = fake_response('401', '{"error":"unauthorized"}')

    Net::HTTP.stub(:new, mock_http(response)) do
      _out, err = capture_io { build.call }
      assert_match 'WARNING', err
      assert_match 'TEST_TOKEN_A', err
    end
  end

  def test_fetch_token_raises_on_empty_token
    File.write(@zshrc, "# empty\n")
    ENV['TEST_EMAIL_A'] = 'user@example.com'
    ENV['TEST_PASS_A']  = 'secret'

    response = fake_response('200', '{"token":null}')

    Net::HTTP.stub(:new, mock_http(response)) do
      _out, err = capture_io { build.call }
      assert_match 'WARNING', err
    end
  end

  # --- remove_obsolete_scripts ---

  def test_removes_obsolete_scripts_that_exist
    script = File.join(@home, 'get_workvector_token.sh')
    File.write(script, '#!/bin/bash')

    provisioner = Klass.new(
      env_dir: @env_dir, zshrc: @zshrc,
      services: [], home: @home
    )
    capture_io { provisioner.call }
    refute File.exist?(script)
  end

  def test_skips_missing_obsolete_scripts_silently
    provisioner = Klass.new(
      env_dir: @env_dir, zshrc: @zshrc,
      services: [], home: @home
    )
    # Should not raise even when none of the scripts exist
    assert_silent { capture_io { provisioner.call } }
  end

  def test_reports_removed_scripts
    script = File.join(@home, 'get_llmmn_token.sh')
    File.write(script, '#!/bin/bash')

    provisioner = Klass.new(
      env_dir: @env_dir, zshrc: @zshrc,
      services: [], home: @home
    )
    out, = capture_io { provisioner.call }
    assert_match 'Removed obsolete script', out
  end

  private

  # Plain stub, not Minitest::Mock: fetch_token reads the body twice on the failure path — once to
  # parse it, once to quote it in the Error message — and a Mock carrying a single :body expect
  # turned that into "No more expects available for :body" instead of the warning under test.
  def fake_response(code, body)
    response = Object.new
    response.define_singleton_method(:code) { code }
    response.define_singleton_method(:body) { body }
    response
  end

  def mock_http(response)
    http_mock = Object.new
    http_mock.define_singleton_method(:use_ssl=) { |_| }
    http_mock.define_singleton_method(:open_timeout=) { |_| }
    http_mock.define_singleton_method(:read_timeout=) { |_| }
    http_mock.define_singleton_method(:request) { |_req| response }
    ->(_, _) { http_mock }
  end
end
