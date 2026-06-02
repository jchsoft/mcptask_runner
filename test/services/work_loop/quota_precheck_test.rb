# frozen_string_literal: true

require 'test_helper'
require_relative 'triage_test_helper'

# The pre-run quota gate is now pure Ruby + REST (QuotaGuard.exceeded?), independent of
# anything the triage agent reports. Triage's job is model + task selection only.
class WorkLoopQuotaPrecheckTest < Minitest::Test
  include TriageTestHelper
  include QuotaTestHelper

  def success_triage_mock(task_id: 123)
    mock = Object.new
    mock.define_singleton_method(:run) do
      { 'status' => 'success', 'recommended_model' => 'genius', 'task_id' => task_id, 'resuming' => false }
    end
    mock
  end

  def capturing_executor
    executor = Object.new
    runs = []
    executor.define_singleton_method(:run) do
      runs << true
      { 'status' => 'success' }
    end
    executor.define_singleton_method(:run_count) { runs.length }
    executor
  end

  def test_skips_execution_when_rest_quota_exceeded
    executor = capturing_executor
    stub_quota(worked: 9.0, per_day: 8.0) do
      McptaskRunner::ClaudeCode::Triage.stub(:new, success_triage_mock) do
        McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
          result = McptaskRunner::WorkLoop.new.execute(:once)
          assert_equal 'quota_exceeded', result['status']
          assert_equal 0, executor.run_count, 'executor must not run when REST quota already exceeded'
        end
      end
    end
  end

  def test_fail_closed_skips_execution_when_rest_unavailable
    executor = capturing_executor
    stub_quota(rest_ok: false) do
      McptaskRunner::ClaudeCode::Triage.stub(:new, success_triage_mock) do
        McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
          result = McptaskRunner::WorkLoop.new.execute(:once)
          assert_equal 'quota_exceeded', result['status']
          assert_equal 0, executor.run_count, 'REST failure fails closed — no execution'
        end
      end
    end
  end

  def test_proceeds_when_ignore_quota_even_if_rest_exceeded
    executor = capturing_executor
    stub_quota(worked: 9.0, per_day: 8.0) do
      McptaskRunner::ClaudeCode::Triage.stub(:new, success_triage_mock) do
        McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
          result = McptaskRunner::WorkLoop.new(ignore_quota: true).execute(:once)
          assert_equal 'success', result['status']
          assert_equal 1, executor.run_count
        end
      end
    end
  end

  def test_proceeds_when_under_quota
    executor = capturing_executor
    # default under-quota verdict from test_helper
    with_triage_stub do
      McptaskRunner::ClaudeCode::Honest.stub(:new, executor) do
        result = McptaskRunner::WorkLoop.new.execute(:once)
        assert_equal 'success', result['status']
      end
    end
  end

  def test_queue_auto_squash_stops_when_quota_exceeded
    executor = capturing_executor
    stub_quota(worked: 9.0, per_day: 8.0) do
      McptaskRunner::ClaudeCode::Triage.stub(:new, success_triage_mock) do
        McptaskRunner::ClaudeCode::QueueAutoSquash.stub(:new, executor) do
          Kernel.stub(:sleep, nil) do
            results = McptaskRunner::WorkLoop.new.execute(:queue_auto_squash)
            assert_equal 'quota_exceeded', results.last['status']
            assert_equal 0, executor.run_count
          end
        end
      end
    end
  end
end
