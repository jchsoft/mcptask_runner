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
    @helper_bin      = File.join(@tmpdir, 'claude_bin')
    FileUtils.mkdir_p(@target_dir)

    @prev_mt     = ENV.delete('MCPTASK_TOKEN')
    @prev_stdin  = $stdin
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
    ENV['MCPTASK_TOKEN'] = @prev_mt if @prev_mt
    $stdin = @prev_stdin if @prev_stdin
  end

  # --- helpers ---

  def build(opts = {})
    Klass.new(
      target_dir:       @target_dir,
      dirs:             { launch_agents: @launch_agents, log_base: @log_base_dir, helper_bin: @helper_bin },
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
    assert_match 'MCPTASK_TOKEN', err
  end

  def test_missing_tokens_write_placeholder_in_plist
    capture_io { build.call }
    assert_match 'SET_MCPTASK_TOKEN_HERE', plist_content
  end

  def test_present_env_tokens_written_to_plist
    ENV['MCPTASK_TOKEN'] = 'tok_mt_789'

    capture_io { build.call }
    assert_match 'tok_mt_789', plist_content
  end

  def test_independent_service_tokens_not_written_to_plist
    capture_io { build.call }
    refute_match 'WORKVECTOR_KAMR_TOKEN', plist_content
    refute_match 'LLMMN_TOKEN',           plist_content
  end

  # --- bundled skills exist in gem ---

  def test_all_bundled_skill_files_present
    SI::SKILL_NAMES.each do |skill|
      path = File.join(SI::SKILLS_SOURCE_DIR, skill, 'SKILL.md')
      assert File.exist?(path), "Bundled skill missing: config/skills/#{skill}/SKILL.md"
    end
  end

  # --- helper binaries ---

  def test_all_bundled_helper_binaries_present
    SI::HELPER_BINARIES.each do |binary|
      assert File.exist?(SI.helper_src(binary)), "Bundled helper binary missing: config/helpers/#{binary}"
    end
  end

  def test_installs_helper_binaries_into_bin_dir
    capture_io { build.call }
    SI::HELPER_BINARIES.each do |binary|
      dest = File.join(@helper_bin, binary)
      assert File.exist?(dest), "Helper binary not installed: #{binary}"
      assert File.executable?(dest), "Helper binary not executable: #{binary}"
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

  # --- bug destination config ---
  #
  # The Installer writes the bug destination into the unified
  # config/mcptask_runner.yml under the `bug_destination:` key.

  def bug_destination_path
    File.join(@target_dir, 'config', 'mcptask_runner.yml')
  end

  def bug_destination_section
    assert File.exist?(bug_destination_path), "Config not found at #{bug_destination_path}"
    payload = YAML.safe_load(File.read(bug_destination_path))
    assert payload.is_a?(Hash), "unified config must be a Hash, got #{payload.class}"
    payload.fetch('bug_destination', {})
  end

  def test_writes_bug_destination_section_when_epic_id_provided
    capture_io { build(bug_dest: { relative_id: 42_001 }).call }

    section = bug_destination_section
    assert_equal 42_001, section['epic_relative_id']
  end

  def test_writes_bug_destination_with_epic_name_when_provided
    capture_io { build(bug_dest: { relative_id: 42_001, name: 'Auto-bugs' }).call }

    section = bug_destination_section
    assert_equal 42_001, section['epic_relative_id']
    assert_equal 'Auto-bugs', section['epic_name']
  end

  def test_omits_epic_name_when_not_provided
    capture_io { build(bug_dest: { relative_id: 42_001 }).call }

    section = bug_destination_section
    refute section.key?('epic_name'), 'epic_name should be absent when not provided'
  end

  def test_writes_root_marker_when_blank_epic_id_and_no_existing_file
    # blank input → leaves project-root placement; bug_destination section is
    # written but empty so the user can later retarget by editing in place.
    $stdin = StringIO.new("\n")
    capture_io { build.call }

    assert File.exist?(bug_destination_path), 'unified config should still be written'
    section = bug_destination_section
    assert_nil section['epic_relative_id']
  ensure
    $stdin = @prev_stdin if @prev_stdin
  end

  def test_does_not_overwrite_existing_destination_without_force
    FileUtils.mkdir_p(File.join(@target_dir, 'config'))
    File.write(bug_destination_path, "bug_destination:\n  epic_relative_id: 99999\n  epic_name: existing\n")

    capture_io { build.call }  # no bug_epic_relative_id → no override

    section = bug_destination_section
    assert_equal 99_999, section['epic_relative_id'], 'existing section must NOT be overwritten when no epic id provided'
    assert_equal 'existing', section['epic_name']
  end

  def test_explicit_epic_id_overrides_existing_without_force
    FileUtils.mkdir_p(File.join(@target_dir, 'config'))
    File.write(bug_destination_path, "bug_destination:\n  epic_relative_id: 99999\n  epic_name: existing\n")

    capture_io { build(bug_dest: { relative_id: 42_001 }).call }

    section = bug_destination_section
    assert_equal 42_001, section['epic_relative_id'], 'explicit epic id always wins, even without force'
  end

  def test_force_overwrites_existing_destination
    FileUtils.mkdir_p(File.join(@target_dir, 'config'))
    File.write(bug_destination_path, "bug_destination:\n  epic_relative_id: 99999\n")

    capture_io { build(force: true, bug_dest: { relative_id: 42_001 }).call }

    section = bug_destination_section
    assert_equal 42_001, section['epic_relative_id']
  end

  def test_keeps_existing_destination_when_no_epic_id_provided_and_no_force
    FileUtils.mkdir_p(File.join(@target_dir, 'config'))
    File.write(bug_destination_path, "bug_destination:\n  epic_relative_id: 12345\n  epic_name: keep\n")

    out, = capture_io { build.call }

    assert_match 'leaving untouched', out
    section = bug_destination_section
    assert_equal 12_345, section['epic_relative_id']
    assert_equal 'keep', section['epic_name']
  end

  def test_prompts_for_epic_relative_id_interactively
    $stdin = StringIO.new("77777\n")
    out, = capture_io { build.call }

    assert_match 'Epic relative_id', out
    assert_match 'Bug destination written', out
    section = bug_destination_section
    assert_equal 77_777, section['epic_relative_id']
  ensure
    $stdin = @prev_stdin if @prev_stdin
  end

  def test_raises_on_non_numeric_epic_input
    $stdin = StringIO.new("not-a-number\n")
    err = assert_raises(Klass::Error) { capture_io { build.call } }
    assert_match(/Invalid Epic relative_id/, err.message)
  ensure
    $stdin = @prev_stdin if @prev_stdin
  end

  def test_raises_on_zero_or_negative_epic_input
    $stdin = StringIO.new("0\n")
    err = assert_raises(Klass::Error) { capture_io { build.call } }
    assert_match(/Invalid Epic relative_id/, err.message)
  ensure
    $stdin = @prev_stdin if @prev_stdin
  end
end
