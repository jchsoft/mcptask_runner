# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module McptaskRunner
  # Shared primitive used by Installer and Updater: constants, skill copy helpers, manifest I/O.
  module SkillInstaller
    SKILLS_SOURCE_DIR  = File.expand_path('../../../config/skills', __dir__)
    HELPERS_SOURCE_DIR = File.expand_path('../../../config/helpers', __dir__)
    SKILL_NAMES = %w[
      ci-runner ci-start ci-wait wait-unlock
      test-runner test-start test-wait
      discover memory-search mcptask-read mcptask-write
    ].freeze
    # Full dependency closure the CI/test skills need in ~/.claude/bin — the skills
    # invoke the first few, and those shell out (via absolute ~/.claude/bin/ paths) to
    # the rest. Ship all of them from config/helpers/ so a fresh install is self-contained.
    HELPER_BINARIES = %w[ci_wait ci_start test_start test_lock run_with_log
                         check_test_lock _ci_filter_tail kill_tree runner-log].freeze
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

    def default_helper_bin_dir
      File.expand_path('~/.claude/bin')
    end

    def helper_src(binary)
      File.join(HELPERS_SOURCE_DIR, binary)
    end

    # Copies the bundled CI/test helper binaries from config/helpers/ into bin_dir
    # (default ~/.claude/bin), making a fresh install self-contained. Overwrites any
    # existing copy and restores the executable bit. Warns — rather than raising — if a
    # source binary is missing from the gem so the rest of the install still completes.
    def install_helper_binaries(bin_dir = default_helper_bin_dir)
      FileUtils.mkdir_p(bin_dir)
      installed = HELPER_BINARIES.map do |binary|
        source = helper_src(binary)
        next warn("[SkillInstaller] WARNING: bundled helper binary missing from gem: #{binary}") unless File.exist?(source)

        dest = File.join(bin_dir, binary)
        FileUtils.cp(source, dest)
        FileUtils.chmod(0o755, dest)
        binary
      end.compact
      puts "[SkillInstaller] Helper binaries: #{installed.size} installed into #{bin_dir}"
    end
  end
end
