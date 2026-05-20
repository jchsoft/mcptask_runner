# frozen_string_literal: true

require 'test_helper'

class StallDetectorTest < Minitest::Test
  def setup
    @detector = McptaskRunner::StallDetector.new('test')
  end

  # ---- Edit failure streak ----

  def test_edit_failure_streak_does_not_fire_below_limit
    pair_edit_failure(file: 'a.rb', old: 'foo')
    pair_edit_failure(file: 'a.rb', old: 'foo')

    refute @detector.observe_tool_result(tool_result('e3', error: true)),
           'Below limit (2 failures) should not fire'
  end

  def test_edit_failure_streak_fires_on_third_consecutive_error
    pair_edit_failure(file: 'a.rb', old: 'foo')
    pair_edit_failure(file: 'a.rb', old: 'foo')
    stall = pair_edit_failure(file: 'a.rb', old: 'foo')

    refute_nil stall
    assert_equal :edit_failures, stall.reason
    assert_equal 3, stall.count
  end

  def test_edit_failure_streak_resets_on_success
    pair_edit_failure(file: 'a.rb', old: 'foo')
    pair_edit_failure(file: 'a.rb', old: 'foo')
    pair_edit_success(file: 'a.rb', old: 'foo') # streak resets here

    # Two more failures should not trigger — streak was reset to zero
    pair_edit_failure(file: 'a.rb', old: 'bar')
    stall = pair_edit_failure(file: 'a.rb', old: 'bar')

    assert_nil stall, 'Streak should reset after a successful edit'
  end

  def test_write_tool_counts_toward_edit_streak
    pair_write_failure(file: 'x.rb')
    pair_write_failure(file: 'x.rb')
    stall = pair_write_failure(file: 'x.rb')

    refute_nil stall
    assert_equal :edit_failures, stall.reason
  end

  # ---- Bash failure loop ----

  def test_bash_failure_loop_fires_on_third_same_exit
    pair_bash(command: 'rspec', exit_code: 1, error: true)
    pair_bash(command: 'rspec', exit_code: 1, error: true)
    stall = pair_bash(command: 'rspec', exit_code: 1, error: true)

    refute_nil stall
    assert_equal :bash_failure_loop, stall.reason
    assert_equal 3, stall.count
    assert_match(/exit=1/, stall.detail)
  end

  def test_bash_failure_loop_does_not_fire_when_exit_code_changes
    pair_bash(command: 'rspec', exit_code: 1, error: true)
    pair_bash(command: 'rspec', exit_code: 2, error: true)
    stall = pair_bash(command: 'rspec', exit_code: 1, error: true)

    assert_nil stall, 'Different exit codes break the loop'
  end

  def test_bash_success_does_not_count
    pair_bash(command: 'ls', exit_code: 0, error: false)
    pair_bash(command: 'ls', exit_code: 0, error: false)
    stall = pair_bash(command: 'ls', exit_code: 0, error: false)

    assert_nil stall
  end

  def test_bash_different_commands_tracked_separately
    pair_bash(command: 'rspec', exit_code: 1, error: true)
    pair_bash(command: 'rubocop', exit_code: 1, error: true)
    stall = pair_bash(command: 'flay', exit_code: 1, error: true)

    assert_nil stall
  end

  # ---- Tool signature repeat (loop_signature) ----

  def test_signature_repeat_fires_when_same_read_repeats_without_mutation
    4.times { @detector.observe_tool_use(tool_use('Read', { 'file_path' => '/x.rb', 'offset' => 1, 'limit' => 100 })) }

    # 4th observe_tool_use should return the stall
    stall = @detector.observe_tool_use(tool_use('Read', { 'file_path' => '/x.rb', 'offset' => 1, 'limit' => 100 }))
    refute_nil stall
    assert_equal :loop_signature, stall.reason
    assert_operator stall.count, :>=, 4
  end

  def test_signature_repeat_suppressed_by_intervening_edit
    # 3 reads + successful edit + 2 more reads → 5 reads total but file mutated → no stall
    3.times { @detector.observe_tool_use(tool_use('Read', { 'file_path' => '/x.rb', 'offset' => nil, 'limit' => nil })) }
    pair_edit_success(file: '/x.rb', old: 'foo')
    2.times { @detector.observe_tool_use(tool_use('Read', { 'file_path' => '/x.rb', 'offset' => nil, 'limit' => nil })) }

    stall = @detector.observe_tool_use(tool_use('Read', { 'file_path' => '/x.rb', 'offset' => nil, 'limit' => nil }))
    assert_nil stall, 'Mutation in window should suppress signature-repeat stall'
  end

  def test_different_files_do_not_trigger_signature_loop
    %w[/a.rb /b.rb /c.rb /d.rb /e.rb].each do |path|
      @detector.observe_tool_use(tool_use('Read', { 'file_path' => path, 'offset' => nil, 'limit' => nil }))
    end

    # All different sigs — none repeated
    stall = @detector.observe_tool_use(tool_use('Read', { 'file_path' => '/f.rb', 'offset' => nil, 'limit' => nil }))
    assert_nil stall
  end

  # ---- Polling exemption (ci-wait/test-wait/wait-unlock are designed for re-invocation) ----

  def test_polling_skill_ci_wait_never_triggers_loop_signature
    5.times do
      stall = @detector.observe_tool_use(tool_use('Skill', { 'skill' => 'ci-wait', 'args' => 'self /log/ci.log' }))
      assert_nil stall, "ci-wait polling must never stall"
    end
  end

  def test_polling_skill_test_wait_never_triggers_loop_signature
    5.times do
      stall = @detector.observe_tool_use(tool_use('Skill', { 'skill' => 'test-wait', 'args' => 'self /log/test.log' }))
      assert_nil stall
    end
  end

  def test_polling_skill_wait_unlock_never_triggers_loop_signature
    5.times do
      stall = @detector.observe_tool_use(tool_use('Skill', { 'skill' => 'wait-unlock', 'args' => '' }))
      assert_nil stall
    end
  end

  def test_polling_bash_ci_wait_script_never_triggers_loop_signature
    cmd = '~/.claude/bin/ci_wait "/log/ci.log" "self" 540'
    5.times do
      stall = @detector.observe_tool_use(tool_use('Bash', { 'command' => cmd }))
      assert_nil stall
    end
  end

  def test_polling_bash_test_wait_script_never_triggers_loop_signature
    cmd = '~/.claude/bin/test_wait "/log/test.log" "self" 540'
    5.times do
      stall = @detector.observe_tool_use(tool_use('Bash', { 'command' => cmd }))
      assert_nil stall
    end
  end

  def test_non_polling_skill_still_stalls_on_loop_signature
    4.times { @detector.observe_tool_use(tool_use('Skill', { 'skill' => 'some-other-skill', 'args' => 'x' })) }
    stall = @detector.observe_tool_use(tool_use('Skill', { 'skill' => 'some-other-skill', 'args' => 'x' }))

    refute_nil stall
    assert_equal :loop_signature, stall.reason
  end

  def test_non_polling_bash_still_stalls_on_loop_signature
    cmd = 'grep ci_wait some-other-log'  # mentions ci_wait but not the script path
    4.times { @detector.observe_tool_use(tool_use('Bash', { 'command' => cmd })) }
    stall = @detector.observe_tool_use(tool_use('Bash', { 'command' => cmd }))

    refute_nil stall, 'Bash referencing ci_wait but not the script must still be eligible for stall'
    assert_equal :loop_signature, stall.reason
  end

  # ---- Helpers ----

  private

  def tool_use(name, input, id: nil)
    { 'type' => 'tool_use', 'id' => id || "use_#{rand(10**9)}", 'name' => name, 'input' => input }
  end

  def tool_result(use_id, error: false, content: 'output')
    { 'type' => 'tool_result', 'tool_use_id' => use_id, 'is_error' => error, 'content' => content }
  end

  def pair_edit_failure(file:, old:)
    use = tool_use('Edit', { 'file_path' => file, 'old_string' => old })
    @detector.observe_tool_use(use)
    @detector.observe_tool_result(tool_result(use['id'], error: true, content: 'String not found'))
  end

  def pair_edit_success(file:, old:)
    use = tool_use('Edit', { 'file_path' => file, 'old_string' => old })
    @detector.observe_tool_use(use)
    @detector.observe_tool_result(tool_result(use['id'], error: false, content: 'edited'))
  end

  def pair_write_failure(file:)
    use = tool_use('Write', { 'file_path' => file, 'content' => 'data' })
    @detector.observe_tool_use(use)
    @detector.observe_tool_result(tool_result(use['id'], error: true, content: 'permission denied'))
  end

  def pair_bash(command:, exit_code:, error:)
    use = tool_use('Bash', { 'command' => command })
    @detector.observe_tool_use(use)
    @detector.observe_tool_result(tool_result(use['id'], error: error, content: "output\nexit code: #{exit_code}"))
  end
end
