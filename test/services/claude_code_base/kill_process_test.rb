# frozen_string_literal: true

require 'test_helper'

class ClaudeCodeBaseKillProcessTest < Minitest::Test
  def test_kill_process_returns_early_for_nil_pid
    base = McptaskRunner::ClaudeCodeBase.new
    assert_nil base.send(:kill_process, nil)
  end

  def test_kill_process_handles_already_dead_process
    base = McptaskRunner::ClaudeCodeBase.new
    Process.stub(:getpgid, ->(_pid) { raise Errno::ESRCH }) do
      Process.stub(:kill, ->(_sig, _pid) { raise Errno::ESRCH }) do
        assert_nil base.send(:kill_process, 99_999)
      end
    end
  end

  def test_kill_process_escalates_to_sigkill_when_process_does_not_die
    base = McptaskRunner::ClaudeCodeBase.new
    signals_sent = []

    kill_stub = lambda do |sig, _pid|
      signals_sent << sig
      raise Errno::ESRCH if sig == 'KILL'
    end

    Process.stub(:getpgid, 99_999) do
      Process.stub(:kill, kill_stub) do
        base.stub(:sleep, nil) do
          base.send(:kill_process, 99_999)
        end
      end
    end

    assert_includes signals_sent, 'TERM'
    assert_includes signals_sent, 'KILL'
  end

  def test_kill_process_does_not_escalate_when_process_dies_after_sigterm
    base = McptaskRunner::ClaudeCodeBase.new
    signals_sent = []
    check_count = 0

    kill_stub = lambda do |sig, _pid|
      signals_sent << sig
      if sig == 0
        check_count += 1
        raise Errno::ESRCH if check_count >= 1
      end
    end

    Process.stub(:getpgid, 99_999) do
      Process.stub(:kill, kill_stub) do
        base.stub(:sleep, nil) do
          base.send(:kill_process, 99_999)
        end
      end
    end

    assert_includes signals_sent, 'TERM'
    refute_includes signals_sent, 'KILL'
  end

  def test_resolve_process_group_returns_pgid_for_current_process
    base = McptaskRunner::ClaudeCodeBase.new
    pgid = base.send(:resolve_process_group, Process.pid)
    assert_kind_of Integer, pgid
  end

  def test_resolve_process_group_returns_nil_for_dead_process
    base = McptaskRunner::ClaudeCodeBase.new
    pgid = base.send(:resolve_process_group, 99_999_999)
    assert_nil pgid
  end

  def test_safe_kill_returns_false_for_dead_process
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:safe_kill, 'TERM', 99_999_999)
    assert_equal false, result
  end

  def test_safe_kill_returns_true_for_alive_process
    base = McptaskRunner::ClaudeCodeBase.new
    result = base.send(:safe_kill, 0, Process.pid)
    assert_equal true, result
  end

  def test_kill_process_sends_signal_to_negative_pgid
    base = McptaskRunner::ClaudeCodeBase.new
    kill_targets = []

    Process.stub(:getpgid, 42_000) do
      Process.stub(:kill, ->(sig, pid) { kill_targets << [sig, pid]; raise Errno::ESRCH if sig == 'TERM' }) do
        base.send(:kill_process, 99_999)
      end
    end

    assert_includes kill_targets, ['TERM', -42_000]
  end

  def test_kill_process_falls_back_to_pid_when_pgid_unavailable
    base = McptaskRunner::ClaudeCodeBase.new
    kill_targets = []

    Process.stub(:getpgid, ->(_pid) { raise Errno::ESRCH }) do
      Process.stub(:kill, ->(sig, pid) { kill_targets << [sig, pid]; raise Errno::ESRCH if sig == 'TERM' }) do
        base.send(:kill_process, 99_999)
      end
    end

    assert_includes kill_targets, ['TERM', 99_999]
    term_calls = kill_targets.select { |sig, _| sig == 'TERM' }
    assert term_calls.all? { |_, pid| pid > 0 }, 'Should use positive pid when pgid unavailable'
  end

  def test_kill_process_handles_eperm_on_group_kill
    base = McptaskRunner::ClaudeCodeBase.new
    kill_targets = []

    kill_stub = lambda do |sig, pid|
      kill_targets << [sig, pid]
      raise Errno::EPERM if pid == -42_000 && sig == 'TERM'
      raise Errno::ESRCH if pid == 99_999 && sig == 'TERM'
    end

    Process.stub(:getpgid, 42_000) do
      Process.stub(:kill, kill_stub) do
        base.send(:kill_process, 99_999)
      end
    end

    assert_includes kill_targets, ['TERM', -42_000]
    assert_includes kill_targets, ['TERM', 99_999]
  end
end
