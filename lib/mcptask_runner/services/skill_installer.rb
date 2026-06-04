# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module McptaskRunner
  # Shared primitive used by Installer and Updater: constants, skill copy helpers, manifest I/O.
  module SkillInstaller
    SKILLS_SOURCE_DIR = File.expand_path('../../../config/skills', __dir__)
    SKILL_NAMES = %w[
      ci-runner ci-start ci-wait wait-unlock
      test-runner test-start test-wait
      discover memory-search mcptask-read mcptask-write
    ].freeze
    HELPER_BINARIES = %w[ci_wait ci_start test_start test_lock run_with_log].freeze
    MANIFEST_FILE   = '.mcptask_runner_manifest.json'

    module_function

    def src(skill)
      File.join(SKILLS_SOURCE_DIR, skill)
    end

    def dest(target_dir, skill)
      File.join(target_dir, '.claude', 'skills', skill)
    end

    # Unconditionally copies gem's bundled skill into destination, replacing any existing copy.
    def copy!(skill, destination)
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(src(skill), destination)
    end

    # MD5 of all file contents under dir, sorted by path — used to detect changes.
    def content_hash(dir)
      files = Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }.sort
      Digest::MD5.hexdigest(files.map { |f| File.read(f) }.join)
    end

    def manifest_path(target_dir)
      File.join(target_dir, '.claude', 'skills', MANIFEST_FILE)
    end

    # Returns hash mapping skill_name → gem_content_hash recorded at last install/update.
    def read_manifest(target_dir)
      path = manifest_path(target_dir)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      {}
    end

    def write_manifest(target_dir, data)
      path = manifest_path(target_dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data))
    end

    def check_helper_binaries
      bin_dir = File.expand_path('~/.claude/bin')
      missing = HELPER_BINARIES.reject { |b| File.exist?(File.join(bin_dir, b)) }
      return if missing.empty?

      warn '[SkillInstaller] WARNING: missing helper binaries in ~/.claude/bin (required by CI/test skills):'
      missing.each { |b| warn "  • #{b}" }
      warn '[SkillInstaller] Install these from the mcptask_runner dev environment before using CI/test skills.'
    end
  end
end
