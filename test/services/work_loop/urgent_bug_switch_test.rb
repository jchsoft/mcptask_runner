# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class WorkLoopUrgentBugSwitchTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('mcptask_runner_test')
    @prev_pwd = Dir.pwd
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@prev_pwd)
    FileUtils.remove_entry(@tmpdir)
  end

  def loop_with_git(branch:, checkout_success: true, checkout_output: '')
    McptaskRunner::WorkLoop.new.tap do |instance|
      instance.define_singleton_method(:current_git_branch) { branch }
      instance.define_singleton_method(:checkout_main_branch) { [checkout_success, checkout_output] }
    end
  end

  def pin_path
    File.join(@tmpdir, 'tmp', 'mcptask_runner', 'urgent_pin.txt')
  end

  def test_switches_to_main_when_urgent_bug_pending_on_feature_branch
    checkout_invoked = false
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { 'feature/9508-foo' }
    loop_instance.define_singleton_method(:checkout_main_branch) { checkout_invoked = true; [true, ''] }

    result = { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999 }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    assert checkout_invoked
    assert_equal 'urgent_bug_pending', result['status']
  end

  def test_marks_dirty_branch_when_checkout_fails
    loop_instance = loop_with_git(branch: 'feature/9508-foo', checkout_success: false, checkout_output: 'error: local changes')

    result = { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999 }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    assert_equal 'urgent_bug_pending_dirty_branch', result['status']
    assert_equal 'feature/9508-foo', result['dirty_branch']
  end

  def test_no_op_when_already_on_main
    checkout_invoked = false
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { 'main' }
    loop_instance.define_singleton_method(:checkout_main_branch) { checkout_invoked = true; [true, ''] }

    result = { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999 }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    refute checkout_invoked
    assert_equal 'urgent_bug_pending', result['status']
  end

  def test_no_op_when_already_on_master
    checkout_invoked = false
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { 'master' }
    loop_instance.define_singleton_method(:checkout_main_branch) { checkout_invoked = true; [true, ''] }

    result = { 'status' => 'urgent_bug_pending' }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    refute checkout_invoked
  end

  def test_no_op_for_non_urgent_bug_status
    branch_invoked = false
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { branch_invoked = true; 'feature/x' }
    loop_instance.define_singleton_method(:checkout_main_branch) { [true, ''] }

    result = { 'status' => 'success' }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    refute branch_invoked, 'should short-circuit before checking branch'
  end

  def test_no_op_for_non_hash_result
    loop_instance = McptaskRunner::WorkLoop.new
    assert_nil loop_instance.send(:switch_to_main_if_urgent_bug, nil)
  end

  def test_pin_written_after_successful_checkout
    loop_instance = loop_with_git(branch: 'feature/9508-foo', checkout_success: true)
    result = { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999 }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    assert File.exist?(pin_path), 'pin file should exist'
    assert_equal '9999', File.read(pin_path).strip
    assert_equal 9999, loop_instance.instance_variable_get(:@task_id)
  end

  def test_pin_written_when_already_on_main
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { 'main' }

    result = { 'status' => 'urgent_bug_pending', 'bug_task_id' => 7777 }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    assert File.exist?(pin_path)
    assert_equal '7777', File.read(pin_path).strip
    assert_equal 7777, loop_instance.instance_variable_get(:@task_id)
  end

  def test_pin_not_written_on_dirty_branch
    loop_instance = loop_with_git(branch: 'feature/9508-foo', checkout_success: false, checkout_output: 'error: local changes')

    result = { 'status' => 'urgent_bug_pending', 'bug_task_id' => 9999 }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    refute File.exist?(pin_path), 'pin must not be written when checkout failed — manual cleanup required'
  end

  def test_pin_not_written_when_bug_task_id_missing
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { 'main' }

    result = { 'status' => 'urgent_bug_pending' }
    loop_instance.send(:switch_to_main_if_urgent_bug, result)

    refute File.exist?(pin_path)
  end

  def test_recover_urgent_pin_on_init
    FileUtils.mkdir_p(File.dirname(pin_path))
    File.write(pin_path, '4242')

    loop_instance = McptaskRunner::WorkLoop.new
    assert_equal 4242, loop_instance.instance_variable_get(:@task_id)
  end

  def test_explicit_task_id_wins_over_pin_on_init
    FileUtils.mkdir_p(File.dirname(pin_path))
    File.write(pin_path, '4242')

    loop_instance = McptaskRunner::WorkLoop.new(task_id: 1111)
    assert_equal 1111, loop_instance.instance_variable_get(:@task_id)
  end

  def test_release_urgent_pin_if_done_clears_on_terminal_status
    FileUtils.mkdir_p(File.dirname(pin_path))
    File.write(pin_path, '500')
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.instance_variable_set(:@task_id, 500)

    loop_instance.send(:release_urgent_pin_if_done, 500, { 'status' => 'no_more_tasks' })

    refute File.exist?(pin_path)
    assert_nil loop_instance.instance_variable_get(:@task_id)
  end

  def test_release_urgent_pin_if_done_keeps_pin_on_cascading_urgent_bug
    FileUtils.mkdir_p(File.dirname(pin_path))
    File.write(pin_path, '500')
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.instance_variable_set(:@task_id, 500)

    loop_instance.send(:release_urgent_pin_if_done, 500, { 'status' => 'urgent_bug_pending', 'bug_task_id' => 600 })

    assert File.exist?(pin_path), 'cascading sub-bug must leave file in place (switch_to_main re-pins to new id)'
  end

  def test_release_urgent_pin_if_done_skips_when_task_does_not_match_pin
    FileUtils.mkdir_p(File.dirname(pin_path))
    File.write(pin_path, '500')
    loop_instance = McptaskRunner::WorkLoop.new

    loop_instance.send(:release_urgent_pin_if_done, 999, { 'status' => 'success' })

    assert File.exist?(pin_path), 'pin for piece 500 must survive unrelated execution of piece 999'
  end

  def test_cascading_bug_overwrites_pin
    loop_instance = McptaskRunner::WorkLoop.new
    loop_instance.define_singleton_method(:current_git_branch) { 'main' }

    loop_instance.send(:switch_to_main_if_urgent_bug, { 'status' => 'urgent_bug_pending', 'bug_task_id' => 500 })
    assert_equal '500', File.read(pin_path).strip

    loop_instance.send(:switch_to_main_if_urgent_bug, { 'status' => 'urgent_bug_pending', 'bug_task_id' => 600 })
    assert_equal '600', File.read(pin_path).strip
    assert_equal 600, loop_instance.instance_variable_get(:@task_id)
  end
end
