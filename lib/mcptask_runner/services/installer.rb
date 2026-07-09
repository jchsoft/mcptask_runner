# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'yaml'

module McptaskRunner
  # Bootstraps mcptask_runner inside a host Rails project.
  # Part 1: copies bundled Claude Code skills into .claude/skills/.
  # Part 2: generates a macOS LaunchAgent plist for weekday scheduling.
  # Part 3: asks which mcptask.online Epic should hold auto-detected bugs, and
  #         writes config/mcptask_runner.yml (bug_destination: section) so the
  #         runner + BugReporter CLI route new bug pieces into that Epic
  #         instead of the project root.
  #
  # Usage: rake mcptask_runner:install
  class Installer
    Error = Class.new(StandardError)

    RAKE_MODES = {
      '1' => 'mcptask_runner:auto:squash:today',
      '2' => 'mcptask_runner:manual:today'
    }.freeze

    MCPTASK_ONLINE_ENTRY = {
      'type'    => 'sse',
      'url'     => 'https://mcptask.online/mcp/sse',
      'headers' => { 'Authorization' => 'Bearer ${MCPTASK_TOKEN}' }
    }.freeze

    MCPTASK_RUNNER_CONFIG_EXAMPLE = File.expand_path('../../../../config/mcptask_runner.yml.example', __dir__).freeze

    # dirs: optional override paths { launch_agents:, log_base: } — grouped so callers
    # (and tests) pass install destinations as one argument.
    # bug_dest: optional override { relative_id:, name: } for the auto-bug destination.
    # Passing these skips the interactive prompt — used by tests and non-interactive installs.
    def initialize(target_dir: Dir.pwd, force: ENV['FORCE'] == '1', dirs: {}, mode: nil, platform: RbConfig::CONFIG['host_os'],
                   bug_dest: nil)
      @target_dir            = File.expand_path(target_dir)
      @force                 = force
      @launch_agents_dir     = dirs[:launch_agents] || File.expand_path('~/Library/LaunchAgents')
      @log_base_dir          = dirs[:log_base] || File.expand_path('~/logs/mcptask_runner')
      @helper_bin_dir        = dirs[:helper_bin] || SkillInstaller.default_helper_bin_dir
      @mode                  = mode
      @platform              = platform
      @bug_epic_relative_id  = bug_dest && bug_dest[:relative_id]
      @bug_epic_name         = bug_dest && bug_dest[:name]
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def call
      install_skills
      install_helper_binaries
      sync_permissions
      provision_tokens
      configure_mcp_json
      configure_bug_destination
      configure_waiting_strategy
      generate_launch_agent
    end

    private

    def install_skills
      puts '[Installer] Installing skills...'
      manifest       = SkillInstaller.read_manifest(@target_dir)
      added, skipped = [], []

      SkillInstaller::SKILL_NAMES.each do |skill|
        dest = SkillInstaller.dest(@target_dir, skill)
        if File.exist?(dest) && !@force
          skipped << skill
        else
          SkillInstaller.copy!(skill, dest)
          manifest[skill] = SkillInstaller.content_hash(SkillInstaller.src(skill))
          added << skill
        end
      end

      SkillInstaller.write_manifest(@target_dir, manifest)
      added.each   { |s| puts "  [+] #{s}" }
      skipped.each { |s| puts "  [~] #{s} (exists — use FORCE=1 to overwrite)" }
      puts "[Installer] Skills: #{added.size} added, #{skipped.size} skipped."
    end

    def install_helper_binaries
      puts '[Installer] Installing helper binaries...'
      SkillInstaller.install_helper_binaries(@helper_bin_dir)
    end

    def provision_tokens
      require 'mcptask_runner/services/token_provisioner'
      puts '[Installer] Provisioning tokens...'
      TokenProvisioner.call
    end

    def sync_permissions
      puts '[Installer] Syncing permissions...'
      syncer = PermissionSyncer.sync(target_dir: @target_dir)
      puts syncer.report
    end

    def configure_mcp_json
      puts '[Installer] Configuring .mcp.json (mcptask-online entry)...'

      path = mcp_json_path
      data = load_mcp_json || {}
      data['mcpServers'] ||= {}

      existing = data['mcpServers']['mcptask-online']
      if existing == MCPTASK_ONLINE_ENTRY
        puts "[Installer] .mcp.json already contains correct mcptask-online entry — no change"
        return
      end

      data['mcpServers']['mcptask-online'] = MCPTASK_ONLINE_ENTRY
      write_mcp_json(path, data)
      puts "[Installer] .mcp.json updated: #{path}"
    end

    def mcp_json_path
      File.join(@target_dir, '.mcp.json')
    end

    # Writes the bug destination into config/mcptask_runner.yml (unified config)
    # so the runner + BugReporter CLI route bug pieces into a dedicated Epic
    # instead of the project root.
    #
    # Skipped when the unified file already has a `bug_destination:` key and
    # FORCE is not set — the user can edit the file directly to retarget
    # without re-running install. Pass epic_relative_id via the constructor to
    # skip the interactive prompt (used by tests and non-interactive installs).
    def configure_bug_destination
      puts '[Installer] Configuring bug destination (Epic for auto-detected bugs)...'

      unified_path = mcptask_runner_config_path

      if File.exist?(unified_path) && !@force && @bug_epic_relative_id.nil?
        existing = YAML.safe_load_file(unified_path) || {}
        if existing.is_a?(Hash) && existing['bug_destination'].is_a?(Hash) && !existing['bug_destination'].empty?
          puts "[Installer] #{unified_path} already has a bug_destination — leaving untouched (use FORCE=1 to retarget)"
          return
        end
      end

      id   = @bug_epic_relative_id
      name = @bug_epic_name

      if id.nil?
        puts '[Installer] Enter the mcptask.online Epic where auto-detected runner bugs should land.'
        puts '[Installer] (You can find the relative_id in the Epic URL: /pieces/<account>/<relative_id>)'
        id = prompt_epic_relative_id
      end

      write_unified_config_section(unified_path, 'bug_destination', build_bug_destination_payload(id, name))
      if id.nil?
        puts "[Installer] Bug destination left as project root (no Epic configured)"
      else
        puts "[Installer] Bug destination written to #{unified_path} under bug_destination:"
        puts "[Installer] Auto-bugs will land in Epic ##{id}#{name ? " (#{name})" : ''}"
      end
    end

    def mcptask_runner_config_path
      File.join(@target_dir, 'config', 'mcptask_runner.yml')
    end

    def build_bug_destination_payload(id, name)
      payload = {}
      payload['epic_relative_id'] = id.to_i unless id.nil?
      payload['epic_name'] = name.to_s unless name.nil? || name.to_s.empty?
      payload
    end

    def prompt_epic_relative_id
      $stdout.print 'Epic relative_id (positive integer, blank to keep project root): '
      $stdout.flush
      raw = $stdin.gets&.chomp.to_s.strip
      return nil if raw.empty?
      return raw.to_i if raw.match?(/\A\d+\z/) && raw.to_i.positive?

      raise Error, "Invalid Epic relative_id: #{raw.inspect}. Expected a positive integer or blank."
    end

    # Writes the waiting-strategy durations into config/mcptask_runner.yml
    # (unified config) the first time the installer runs. Skipped when the
    # unified file already has a `waiting_strategy:` section — the user
    # edits the file directly to retarget without re-running install.
    # Unlike configure_bug_destination this is OPT-IN: we write the
    # recommended short waits so unattended hosts don't sleep 30 minutes
    # between retries, but operators can delete the section to revert to
    # defaults.
    def configure_waiting_strategy
      puts '[Installer] Configuring waiting strategy (short/long wait durations)...'

      unified_path = mcptask_runner_config_path

      if File.exist?(unified_path)
        existing = YAML.safe_load_file(unified_path) || {}
        if existing.is_a?(Hash) && existing['waiting_strategy'].is_a?(Hash) && !existing['waiting_strategy'].empty?
          puts "[Installer] #{unified_path} already has a waiting_strategy section — leaving untouched (delete the section to use defaults)"
          return
        end
      end

      write_unified_config_section(unified_path, 'waiting_strategy', {
        'short_wait_minutes' => 5,
        'long_wait_minutes' => 30
      })
      puts "[Installer] Waiting strategy written to #{unified_path} under waiting_strategy:"
      puts '[Installer] Edit it to tighten/loosen the no-task retry intervals (default: short=30m, long=60m)'
    end

    # Merges `payload` under the named top-level key in the unified
    # config/mcptask_runner.yml. Preserves any other top-level keys the user
    # has already set (e.g. `models:`, `launcher:`). Creates the file with a
    # "# generated by…" comment so the operator knows it was installer-managed.
    def write_unified_config_section(path, section, payload)
      FileUtils.mkdir_p(File.dirname(path))
      existing = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      existing = {} unless existing.is_a?(Hash)
      existing[section] = payload
      yaml = YAML.dump(existing)
      yaml = yaml.chomp + " # generated by McptaskRunner::Installer\n"
      File.write(path, yaml)
    end

    def write_mcp_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(data)}\n")
    end

    def generate_launch_agent
      unless macos?
        puts '[Installer] LaunchAgent: skipped (not macOS).'
        return
      end

      slug  = project_slug
      label = "online.mcptask.runner-#{slug}"
      plist = File.join(@launch_agents_dir, "#{label}.plist")

      if File.exist?(plist) && !@force
        puts "[Installer] LaunchAgent already exists: #{plist} (use FORCE=1 to overwrite)"
        return
      end

      chosen = @mode || prompt_mode
      FileUtils.mkdir_p(@log_base_dir)
      write_plist(plist, label, slug, chosen)

      puts "[Installer] LaunchAgent written: #{plist}"
      puts '[Installer] To activate, run:'
      puts "  launchctl bootstrap gui/$(id -u) #{plist}"
    end

    def macos?
      /darwin/i.match?(@platform)
    end

    def project_slug
      File.basename(@target_dir).tr('_', '-')
    end

    def prompt_mode
      puts '[Installer] Choose LaunchAgent runner mode:'
      RAKE_MODES.each { |k, v| puts "  #{k}) #{v}" }
      $stdout.print 'Enter choice (1 or 2): '
      $stdout.flush
      choice = $stdin.gets&.chomp.to_s.strip
      RAKE_MODES.fetch(choice) { raise Error, "Invalid mode: #{choice.inspect}. Enter 1 or 2." }
    end

    def write_plist(path, label, slug, rake_task)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, plist_content(label, slug, rake_task))
    end

    def plist_content(label, slug, rake_task)
      log_path  = File.join(@log_base_dir, "#{slug}.log")
      cmd       = xml_escape("cd #{@target_dir} && bundle exec rake #{rake_task} >> #{log_path} 2>&1")
      intervals = (1..5).map { |d| weekday_dict(d) }.join("\n        ")
      env_xml   = env_tokens.map { |k, v| "    <key>#{k}</key>\n    <string>#{v}</string>" }.join("\n")

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{label}</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/bash</string>
            <string>-l</string>
            <string>-c</string>
            <string>#{cmd}</string>
          </array>
          <key>StartCalendarInterval</key>
          <array>
            #{intervals}
          </array>
          <key>EnvironmentVariables</key>
          <dict>
        #{env_xml}
          </dict>
          <key>RunAtLoad</key>
          <false/>
        </dict>
        </plist>
      XML
    end

    def weekday_dict(day)
      <<~XML.chomp
        <dict>
              <key>Weekday</key><integer>#{day}</integer>
              <key>Hour</key><integer>8</integer>
              <key>Minute</key><integer>0</integer>
            </dict>
      XML
    end

    def xml_escape(str)
      str.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def env_tokens
      %w[MCPTASK_TOKEN].each_with_object({}) do |key, hash|
        value = ENV[key].to_s
        value = mcp_json_env(key).to_s if value.empty?
        if value.empty?
          warn "[Installer] WARNING: #{key} not found in ENV or .mcp.json — placeholder written; set it before loading the LaunchAgent."
          value = "SET_#{key}_HERE"
        end
        hash[key] = value
      end
    end

    def mcp_json_env(env_key)
      return nil unless (data = load_mcp_json)

      (data['mcpServers'] || {}).each_value do |server|
        val = (server['env'] || {})[env_key]
        return val if val
      end
      nil
    end

    def load_mcp_json
      path = mcp_json_path
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end
  end
end
