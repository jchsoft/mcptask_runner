# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class InstallerTest < Minitest::Test
  Klass = McptaskRunner::Installer
  SI    = McptaskRunner::SkillInstaller

  def setup
    @tmpdir = Dir.mktmpdir('installer_test')
    @target_dir      = File.join(@tmpdir, 'project_name')
    @launch_agents   = File.join(@tmpdir, 'LaunchAgents')
    @log_base_dir    = File.join(@tmpdir, 'logs')
    FileUtils.mkdir_p(@target_dir)

    @prev_mt  = ENV.delete('MCPTASK_TOKEN')
    @prev_wv  = ENV.delete('WORKVECTOR_KAMR_TOKEN')
    @prev_lt  = ENV.delete('LLMMN_TOKEN')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
    ENV['MCPTASK_TOKEN']         = @prev_mt if @prev_mt
    ENV['WORKVECTOR_KAMR_TOKEN'] = @prev_wv if @prev_wv
    ENV['LLMMN_TOKEN']           = @prev_lt if @prev_lt
  end

  # --- helpers ---

  def build(opts = {})
    Klass.new(
      target_dir:       @target_dir,
      dirs:             { launch_agents: @launch_agents, log_base: @log_base_dir },
      mode:             'mcptask_runner:auto:squash:today',
      platform:         'darwin19.0.0',
      **opts
    )
  end

  def plist_path
    slug = File.basename(@target_dir).tr('_', '-')
    File.join(@launch_agents, "com.karelmracek.mcptask-runner-#{slug}.plist")
  end

  def plist_content
    assert File.exist?(plist_path), "Plist not found at #{plist_path}"
    File.read(plist_path)
  end

  # --- skill install ---

  def test_installs_all_skills
    capture_io { build.call }

    SI::SKILL_NAMES.each do |skill|
      dest = File.join(@target_dir, '.claude', 'skills', skill, 'SKILL.md')
      assert File.exist?(dest), "Expected SKILL.md for #{skill}"
    end
  end

  def test_skips_existing_skills_without_force
    skill = SI::SKILL_NAMES.first
    dest  = File.join(@target_dir, '.claude', 'skills', skill)
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, 'SKILL.md'), 'sentinel')

    out, = capture_io { build(force: false).call }

    assert_match '[~]', out
    assert_equal 'sentinel', File.read(File.join(dest, 'SKILL.md'))
  end

  def test_force_overwrites_existing_skills
    skill = SI::SKILL_NAMES.first
    dest  = File.join(@target_dir, '.claude', 'skills', skill)
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, 'SKILL.md'), 'sentinel')

    capture_io { build(force: true).call }

    refute_equal 'sentinel', File.read(File.join(dest, 'SKILL.md'))
  end

  def test_reports_added_and_skipped_counts
    out, = capture_io { build.call }
    assert_match(/Skills: \d+ added, \d+ skipped/, out)
  end

  # --- slug derivation ---

  def test_project_slug_converts_underscores_to_dashes
    dir = File.join(@tmpdir, 'my_project_ii')
    FileUtils.mkdir_p(dir)
    inst = Klass.new(
      target_dir: dir, dirs: { launch_agents: @launch_agents, log_base: @log_base_dir },
      mode: 'mcptask_runner:manual:today', platform: 'darwin'
    )
    capture_io { inst.call }
    plist = File.join(@launch_agents, 'com.karelmracek.mcptask-runner-my-project-ii.plist')
    assert File.exist?(plist), "Expected plist with dashed slug"
  end

  # --- plist content ---

  def test_plist_contains_correct_label
    capture_io { build.call }
    assert_match 'com.karelmracek.mcptask-runner-project-name', plist_content
  end

  def test_plist_program_arguments_use_bash
    capture_io { build.call }
    assert_match '<string>/bin/bash</string>', plist_content
    assert_match '<string>-l</string>',        plist_content
    assert_match '<string>-c</string>',        plist_content
  end

  def test_plist_program_arguments_contain_chosen_mode
    capture_io { build(mode: 'mcptask_runner:manual:today').call }
    assert_match 'mcptask_runner:manual:today', plist_content
  end

  def test_plist_has_five_weekday_intervals
    capture_io { build.call }
    content = plist_content
    assert_match 'StartCalendarInterval', content
    (1..5).each { |d| assert_match "<integer>#{d}</integer>", content }
  end

  def test_plist_run_at_load_is_false
    capture_io { build.call }
    assert_match '<false/>', plist_content
  end

  def test_plist_shell_command_is_xml_escaped
    capture_io { build.call }
    content = plist_content
    # && → &amp;&amp;, >> → &gt;&gt;
    assert_match '&amp;&amp;', content
    assert_match '&gt;&gt;',   content
  end

  # --- macOS guard ---

  def test_skips_launch_agent_on_non_macos
    out, = capture_io { build(platform: 'linux-gnu').call }
    assert_match 'not macOS', out
    assert_empty Dir.glob(File.join(@launch_agents, '*.plist'))
  end

  # --- existing plist guard ---

  def test_skips_plist_when_exists_without_force
    FileUtils.mkdir_p(@launch_agents)
    File.write(plist_path, 'sentinel')

    out, = capture_io { build(force: false).call }
    assert_match 'already exists', out
    assert_equal 'sentinel', File.read(plist_path)
  end

  def test_force_overwrites_existing_plist
    FileUtils.mkdir_p(@launch_agents)
    File.write(plist_path, 'sentinel')

    capture_io { build(force: true).call }
    refute_equal 'sentinel', File.read(plist_path)
  end

  # --- missing env tokens ---

  def test_warns_about_missing_env_tokens
    _, err = capture_io { build.call }
    assert_match 'MCPTASK_TOKEN',         err
    assert_match 'WORKVECTOR_KAMR_TOKEN', err
    assert_match 'LLMMN_TOKEN',           err
  end

  def test_missing_tokens_write_placeholder_in_plist
    capture_io { build.call }
    assert_match 'SET_MCPTASK_TOKEN_HERE',         plist_content
    assert_match 'SET_WORKVECTOR_KAMR_TOKEN_HERE', plist_content
    assert_match 'SET_LLMMN_TOKEN_HERE',           plist_content
  end

  def test_present_env_tokens_written_to_plist
    ENV['MCPTASK_TOKEN']         = 'tok_mt_789'
    ENV['WORKVECTOR_KAMR_TOKEN'] = 'tok_wv_123'
    ENV['LLMMN_TOKEN']           = 'tok_lt_456'

    capture_io { build.call }
    assert_match 'tok_mt_789', plist_content
    assert_match 'tok_wv_123', plist_content
    assert_match 'tok_lt_456', plist_content
  end

  # --- bundled skills exist in gem ---

  def test_all_bundled_skill_files_present
    SI::SKILL_NAMES.each do |skill|
      path = File.join(SI::SKILLS_SOURCE_DIR, skill, 'SKILL.md')
      assert File.exist?(path), "Bundled skill missing: config/skills/#{skill}/SKILL.md"
    end
  end

  # --- .mcp.json ---

  def mcp_json_path
    File.join(@target_dir, '.mcp.json')
  end

  def mcp_json_content
    assert File.exist?(mcp_json_path), ".mcp.json not found at #{mcp_json_path}"
    JSON.parse(File.read(mcp_json_path))
  end

  def test_creates_mcp_json_with_mcptask_online_entry_when_missing
    refute File.exist?(mcp_json_path)

    capture_io { build.call }

    data = mcp_json_content
    entry = data.fetch('mcpServers').fetch('mcptask-online')
    assert_equal 'sse',  entry['type']
    assert_equal 'https://mcptask.online/mcp/sse', entry['url']
    assert_equal 'Bearer ${MCPTASK_TOKEN}', entry.dig('headers', 'Authorization')
  end

  def test_merges_mcptask_online_entry_into_existing_mcp_json
    existing = {
      'mcpServers' => {
        'llmmn-production' => {
          'type'    => 'sse',
          'url'     => 'https://llm-memory.com/mcp/sse',
          'headers' => { 'Authorization' => 'Bearer ${LLMMN_TOKEN}' }
        }
      }
    }
    File.write(mcp_json_path, JSON.generate(existing))

    capture_io { build.call }

    data = mcp_json_content
    assert data['mcpServers'].key?('llmmn-production'), 'existing server must be preserved'
    assert data['mcpServers'].key?('mcptask-online'),   'mcptask-online must be added'
  end

  def test_idempotent_when_mcptask_online_entry_already_present
    existing = {
      'mcpServers' => {
        'mcptask-online' => {
          'type'    => 'sse',
          'url'     => 'https://mcptask.online/mcp/sse',
          'headers' => { 'Authorization' => 'Bearer ${MCPTASK_TOKEN}' }
        }
      }
    }
    File.write(mcp_json_path, JSON.pretty_generate(existing))
    mtime_before = File.mtime(mcp_json_path)

    out, = capture_io { build.call }

    assert_equal mtime_before, File.mtime(mcp_json_path)
    assert_match 'no change', out
  end

  def test_preserves_literal_mcptask_token_env_reference
    capture_io { build.call }
    raw = File.read(mcp_json_path)
    assert_includes raw, 'Bearer ${MCPTASK_TOKEN}'
    refute_match(/Bearer [A-Za-z0-9._-]{8,}/, raw)
  end
end
