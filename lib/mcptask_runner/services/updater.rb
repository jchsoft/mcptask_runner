# frozen_string_literal: true

require 'fileutils'

module McptaskRunner
  # Refreshes bundled skills in the host project after `bundle update mcptask_runner`.
  # Detects per-skill state using a content-hash manifest written at install time:
  #   MISSING           → skill absent in host → copied (added)
  #   IDENTICAL         → host already matches current gem → skipped (up-to-date)
  #   OUTDATED          → host = old gem baseline, gem has new version → overwritten (updated)
  #   LOCALLY MODIFIED  → host diverged from baseline → warned / backed up with FORCE=1
  #
  # Usage: rake mcptask_runner:update   (set FORCE=1 to overwrite locally-modified skills)
  class Updater
    Error = Class.new(StandardError)

    SkillEntry = Struct.new(:skill, :dest)

    def initialize(target_dir: Dir.pwd, force: ENV['FORCE'] == '1')
      @target_dir = File.expand_path(target_dir)
      @force      = force
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def call
      update_skills
      SkillInstaller.check_helper_binaries
      sync_permissions
    end

    private

    def update_skills
      puts '[Updater] Refreshing skills...'
      manifest = SkillInstaller.read_manifest(@target_dir)
      rows     = []

      SkillInstaller::SKILL_NAMES.each do |skill|
        action = process_skill(skill, manifest)
        rows << [skill, action]
      end

      SkillInstaller.write_manifest(@target_dir, manifest)
      print_summary(rows)
    end

    def process_skill(skill, manifest)
      entry     = SkillEntry.new(skill, SkillInstaller.dest(@target_dir, skill))
      gem_hash  = SkillInstaller.content_hash(SkillInstaller.src(skill))
      host_hash = File.exist?(entry.dest) ? SkillInstaller.content_hash(entry.dest) : nil
      baseline  = manifest[skill]

      action = classify(entry, gem_hash, host_hash, baseline)
      manifest[skill] = gem_hash if %w[added updated force-updated].include?(action)
      action
    end

    def classify(entry, gem_hash, host_hash, baseline)
      return copy_skill(entry, 'added')   if host_hash.nil?
      return 'up-to-date'                 if gem_hash == host_hash
      return copy_skill(entry, 'updated') if baseline && host_hash == baseline

      handle_conflict(entry)
    end

    def copy_skill(entry, label)
      SkillInstaller.copy!(entry.skill, entry.dest)
      label
    end

    def handle_conflict(entry)
      unless @force
        warn "[Updater] conflict — #{entry.skill}: locally modified, skipped (use FORCE=1 to overwrite)"
        return 'conflict-skipped'
      end

      bak = "#{entry.dest}.bak"
      FileUtils.rm_rf(bak)
      FileUtils.cp_r(entry.dest, bak)
      SkillInstaller.copy!(entry.skill, entry.dest)
      puts "[Updater] #{entry.skill}: backed up to #{File.basename(bak)}, overwritten"
      'force-updated'
    end

    def sync_permissions
      puts '[Updater] Syncing permissions...'
      syncer = PermissionSyncer.sync(target_dir: @target_dir)
      puts syncer.report
    end

    def print_summary(rows)
      width = rows.map { |skill, _| skill.length }.max.to_i
      puts
      puts format("  %-#{width}s  %s", 'Skill', 'Action')
      puts "  #{'-' * width}  #{'-' * 14}"
      rows.each { |skill, action| puts format("  %-#{width}s  %s", skill, action) }
      puts
    end
  end
end
