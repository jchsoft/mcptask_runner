# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseCommandTest < Minitest::Test
  def test_build_command_without_continue_session
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    cmd = base.send(:build_command, ['/usr/bin/claude'], 'test instructions', continue_session: false)

    assert_equal '/usr/bin/claude', cmd[0]
    refute_includes cmd, '--continue'
    assert_includes cmd, '-p'
    assert_includes cmd, 'test instructions'
    assert_includes cmd, '--model'
    genius_id = McptaskRunner::ClaudeCodeBase::MODEL_IDS.fetch('genius')
    assert_includes cmd, genius_id, 'genius alias must map to configured model ID'
    refute_includes cmd, "#{genius_id}[1m]", 'must not request 1M context variant'
  end

  def test_build_command_with_continue_session
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    cmd = base.send(:build_command, ['/usr/bin/claude'], 'test instructions', continue_session: true)

    assert_equal '/usr/bin/claude', cmd[0]
    assert_equal '--continue', cmd[1], 'Continue flag should be second element'
    assert_includes cmd, '-p'
    assert_includes cmd, 'test instructions'
  end

  # A headless child entering plan mode waits forever for interactive approval — the flag must be
  # present on every invocation, continue or fresh.
  def test_build_command_always_disallows_plan_mode_tools
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    [true, false].each do |continue_session|
      cmd = base.send(:build_command, ['/usr/bin/claude'], 'test instructions', continue_session: continue_session)

      assert_includes cmd, '--disallowedTools'
      assert_includes cmd, 'EnterPlanMode,ExitPlanMode'
    end
  end

  def test_build_command_omits_max_turns_when_nil
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    cmd = base.send(:build_command, ['/usr/bin/claude'], 'test instructions', continue_session: false)

    refute_includes cmd, '--max-turns'
  end

  def test_build_command_includes_max_turns_when_set
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }
    base.define_singleton_method(:max_turns) { 150 }

    cmd = base.send(:build_command, ['/usr/bin/claude'], 'test instructions', continue_session: false)

    assert_includes cmd, '--max-turns'
    assert_includes cmd, '150'
  end

  def test_base_command_defaults_to_resolved_claude_path
    # CLAUDE_COMMAND_PREFIX is a load-time constant from config/mcptask_runner.yml. The fallback
    # to the resolved claude path is only observable on hosts WITHOUT a launcher override.
    skip 'host has a config/mcptask_runner.yml launcher override' if McptaskRunner::ClaudeCodeBase::CLAUDE_COMMAND_PREFIX

    base = McptaskRunner::ClaudeCodeBase.new
    base.stub(:resolve_claude_path, '/usr/bin/claude') do
      assert_equal ['/usr/bin/claude'], base.send(:base_command)
    end
  end

  def test_build_command_honors_multi_token_launcher_prefix
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    cmd = base.send(:build_command, %w[ollama launch claude], 'test instructions', continue_session: false)

    assert_equal %w[ollama launch claude], cmd[0, 3], 'launcher prefix must lead the command'
    assert_includes cmd, '-p'
    assert_includes cmd, '--output-format=stream-json'
  end

  def test_effective_model_name_maps_alias_to_pinned_id
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'smart' }

    assert_equal McptaskRunner::ClaudeCodeBase::MODEL_IDS.fetch('smart'), base.send(:effective_model_name)
  end

  def test_effective_model_name_passes_through_unknown_id
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'claude-future-99' }

    assert_equal 'claude-future-99', base.send(:effective_model_name)
  end

  # Forked skills (model: haiku/sonnet/opus in frontmatter) resolve those aliases via the
  # ANTHROPIC_DEFAULT_*_MODEL env vars, NOT the main process --model flag. When config/mcptask_runner.yml
  # pins a backend, the pinned IDs must flow to forks too, or `model: haiku` forks request a built-in
  # Anthropic ID the backend rejects ("model ... may not exist").
  def test_fork_model_env_maps_tier_aliases_when_models_pinned
    skip 'host has no pinned model config (generic aliases)' unless McptaskRunner::ClaudeCodeBase::MODEL_IDS_FROM_FILE

    env = McptaskRunner::ClaudeCodeBase::FORK_MODEL_ENV
    ids = McptaskRunner::ClaudeCodeBase::MODEL_IDS

    assert_equal ids.fetch('genius'), env['ANTHROPIC_DEFAULT_OPUS_MODEL']
    assert_equal ids.fetch('smart'), env['ANTHROPIC_DEFAULT_SONNET_MODEL']
    assert_equal ids.fetch('primitive'), env['ANTHROPIC_DEFAULT_HAIKU_MODEL']
  end

  def test_fork_model_env_empty_without_pinned_models
    skip 'host has pinned model config (config/mcptask_runner.yml)' if McptaskRunner::ClaudeCodeBase::MODEL_IDS_FROM_FILE

    # Without pinned IDs the generic values are aliases ('haiku'), not full names — leaving the
    # env unset lets the CLI use its correct Anthropic defaults.
    assert_empty McptaskRunner::ClaudeCodeBase::FORK_MODEL_ENV
  end
end
