# frozen_string_literal: true

# Shared helper for WorkLoop tests that need triage mocking
module TriageTestHelper
  def triage_mock(task_id: 123, recommended_model: 'genius', resuming: false, piece_type: nil, story_id: nil)
    mock = Object.new
    mock.define_singleton_method(:run) do
      result = { 'status' => 'success', 'recommended_model' => recommended_model, 'task_id' => task_id,
                 'resuming' => resuming, 'hours' => { 'per_day' => 8, 'task_estimated' => 2, 'already_worked' => 0 } }
      result['piece_type'] = piece_type if piece_type
      result['story_id'] = story_id if story_id
      result
    end
    mock
  end

  def with_triage_stub(**kwargs, &block)
    McptaskRunner::ClaudeCode::Triage.stub(:new, triage_mock(**kwargs), &block)
  end
end
