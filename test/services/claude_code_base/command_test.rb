# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseCommandTest < Minitest::Test
  def test_build_command_without_continue_session
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    cmd = base.send(:build_command, '/usr/bin/claude', 'test instructions', continue_session: false)

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

    cmd = base.send(:build_command, '/usr/bin/claude', 'test instructions', continue_session: true)

    assert_equal '/usr/bin/claude', cmd[0]
    assert_equal '--continue', cmd[1], 'Continue flag should be second element'
    assert_includes cmd, '-p'
    assert_includes cmd, 'test instructions'
  end

  def test_build_command_omits_max_turns_when_nil
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }

    cmd = base.send(:build_command, '/usr/bin/claude', 'test instructions', continue_session: false)

    refute_includes cmd, '--max-turns'
  end

  def test_build_command_includes_max_turns_when_set
    base = McptaskRunner::ClaudeCodeBase.new
    base.define_singleton_method(:model_name) { 'genius' }
    base.define_singleton_method(:max_turns) { 150 }

    cmd = base.send(:build_command, '/usr/bin/claude', 'test instructions', continue_session: false)

    assert_includes cmd, '--max-turns'
    assert_includes cmd, '150'
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
end
