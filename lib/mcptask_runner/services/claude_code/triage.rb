# frozen_string_literal: true

require_relative '../claude_code_base'

module McptaskRunner
  module ClaudeCode
    # Triage step — smart call that analyzes task complexity and recommends optimal model.
    # Sonnet (was Haiku before 2026-05-01): branchy prompt + tool-call ordering caused Haiku
    # hallucinations (wrong task_id, skipped quota tool). Triage cost is negligible vs the
    # task it gates, so reliability wins.
    #
    # Prompt building delegated to Triage::Prompt::* — one class per input shape, no
    # `if @story_id` / `if @task_id` branches inside any single prompt.
    class Triage < ClaudeCodeBase
      def initialize(verbose: false, task_id: nil, story_id: nil, snapshot_builder: nil)
        super(verbose: verbose, snapshot_builder: snapshot_builder)
        @task_id = task_id
        @story_id = story_id
      end

      def model_name = 'smart'
      def max_turns = 30

      private

      def accept_edits?
        false
      end

      def build_instructions
        prompt_builder.build
      end

      def prompt_builder
        if @story_id
          Prompt::Story.new(story_id: @story_id)
        elsif @task_id
          Prompt::TaskPinned.new(task_id: @task_id)
        else
          Prompt::TaskDiscovery.new(project_id: project_relative_id)
        end
      end
    end
  end
end

require_relative 'triage/prompt/base'
require_relative 'triage/prompt/task_base'
require_relative 'triage/prompt/task_discovery'
require_relative 'triage/prompt/task_pinned'
require_relative 'triage/prompt/story'
