# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'

module McptaskRunner
  # Bootstraps mcptask_runner inside a host Rails project.
  # Part 1: copies bundled Claude Code skills into .claude/skills/.
  # Part 2: generates a macOS LaunchAgent plist for weekday scheduling.
  #
  # Usage: rake mcptask_runner:install
  class Installer
    Error = Class.new(StandardError)

    RAKE_MODES = {
      '1' => 'mcptask_runner:auto:squash:today',
      '2' => 'mcptask_runner:manual:today'
    }.freeze

    # dirs: optional override paths { launch_agents:, log_base: } — grouped so callers
    # (and tests) pass install destinations as one argument.
    def initialize(target_dir: Dir.pwd, force: ENV['FORCE'] == '1', dirs: {}, mode: nil, platform: RbConfig::CONFIG['host_os'])
      @target_dir        = File.expand_path(target_dir)
      @force             = force
      @launch_agents_dir = dirs[:launch_agents] || File.expand_path('~/Library/LaunchAgents')
      @log_base_dir      = dirs[:log_base] || File.expand_path('~/logs/mcptask_runner')
      @mode              = mode
      @platform          = platform
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def call
      install_skills
      check_helper_binaries
      sync_permissions
      provision_tokens
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

    def check_helper_binaries
      SkillInstaller.check_helper_binaries
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

    def generate_launch_agent
      unless macos?
        puts '[Installer] LaunchAgent: skipped (not macOS).'
        return
      end

      slug  = project_slug
      label = "com.karelmracek.mcptask-runner-#{slug}"
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
      %w[MCPTASK_TOKEN WORKVECTOR_KAMR_TOKEN LLMMN_TOKEN].each_with_object({}) do |key, hash|
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
      path = File.join(@target_dir, '.mcp.json')
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end
  end
end
