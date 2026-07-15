# frozen_string_literal: true

require_relative '../../../concerns/instruction_building'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Shared helpers for triage prompt builders.
        # Each subclass owns a single non-conditional prompt — no `if @task_id` etc inside.
        # Uses InstructionBuilding for result_format_instruction + task_fetch_url.
        class Base
          include McptaskRunner::Concerns::InstructionBuilding

          def build
            raise NotImplementedError, "#{self.class} must implement #build"
          end

          private

          def model_selection_rules
            <<~RULES.strip
              MODEL SELECTION (pick one: "genius"/"smart"/"primitive"):

              RESUMING OVERRIDE: if resuming=true → recommended_model="genius" ALWAYS (previous attempt didn't finish — needs strongest model regardless of complexity)

              "primitive": trivial — typo fix, single CSS change, one-line config

              "genius" ONLY: UI elements/improvements/beautification, complex architecture (models+associations, multi-service, migrations w/ data transforms), security (auth/encryption), ambiguous requirements, Story type, FIXING FAILING TESTS / debugging test failures (red→green, flaky tests, CI-failing specs — Sonnet historically struggles here)

              "smart" (DEFAULT): everything else — CRUD, refactoring, bug fixes, writing NEW tests, simple frontend, validations/scopes/callbacks, config/locale/docs, API endpoints

              DURATION HINT: <1 hour → lean smart/primitive
            RULES
          end

          def triage_status_instruction(status_entries:)
            <<~INSTRUCTION.strip
              Status:
              #{status_entries}
            INSTRUCTION
          end

          # One-time preamble establishing the general rule: any tool the prompt tells the agent to
          # use but which is absent from its active tool list is DEFERRED (schema not loaded yet),
          # NOT missing and NOT a failure. Stated generically so it covers every deferred tool — MCP
          # tools especially — not just ReadMcpResourceTool. Without this a triage child that merely
          # NOTICES ReadMcpResourceTool is absent gives up and emits status "error" (the prompt's
          # "On MCP failure: STOP" reads a deferred tool as an outage), killing the whole work loop.
          def deferred_tools_note
            <<~NOTE.strip
              DEFERRED TOOLS: every MCP tool (e.g. ReadMcpResourceTool) is DEFERRED — its schema is not loaded, so it is ABSENT from your active tool list until you load it. A tool these instructions tell you to use but you do not see is DEFERRED, NOT missing and NOT an MCP failure. Load it FIRST with ToolSearch query "select:<ToolName>" (e.g. "select:ReadMcpResourceTool"), THEN call it. NEVER emit an error/failure status because a tool "isn't available" — ToolSearch it first.
            NOTE
          end

          # Canonical MCP-fetch directive, shared by every triage prompt step that loads a piece.
          def mcp_fetch(uri)
            %(INVOKE ReadMcpResourceTool with server="mcptask-online", uri="#{uri}" — DIRECT MCP. Do NOT use /mcptask-read skill.)
          end

          # Safety note appended after the first fetch in each prompt.
          def mcp_safety_note
            'NEVER use Bash/curl/Net::HTTP — API uses internal id (not relative_id), returns WRONG piece. On MCP failure: STOP, emit error status.'
          end
        end
      end
    end
  end
end
