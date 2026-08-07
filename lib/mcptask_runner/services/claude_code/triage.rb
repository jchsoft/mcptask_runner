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
      # A tool_use of one of these in the stream is the only proof the child really looked the piece
      # up. Matched on the tool_use JSON shape, not the bare name: a child that merely NARRATES
      # "I need to fetch the task via ReadMcpResourceTool" writes that name into its thinking text
      # too, and thinking is not evidence.
      FETCH_TOOL_NAMES = %w[
        ReadMcpResourceTool
        mcp__mcptask-online__GetPieceTool
        mcp__mcptask-online__GetNextTaskTool
        mcp__mcptask-online__ListPiecesTool
      ].freeze

      FETCH_TOOL_USE_PATTERN = /"name"\s*:\s*"(?:#{FETCH_TOOL_NAMES.map { |name| Regexp.escape(name) }.join('|')})"/

      def initialize(verbose: false, task_id: nil, story_id: nil, snapshot_builder: nil)
        super(verbose: verbose, snapshot_builder: snapshot_builder)
        @task_id = task_id
        @story_id = story_id
      end

      def model_name = 'smart'
      def max_turns = 30

      # Stamp the result with whether a piece was actually fetched, so TriageExecution can throw
      # away a made-up pick (see Concerns::TriageExecution#run_verified_triage). Only the real
      # Triage sets this key — a missing key means "no verdict", never "unverified".
      def run
        super.tap { |result| result['fetch_observed'] = piece_fetch_observed? if result.is_a?(Hash) }
      end

      private

      def piece_fetch_observed?
        @accumulated_output.to_s.match?(FETCH_TOOL_USE_PATTERN)
      end

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
