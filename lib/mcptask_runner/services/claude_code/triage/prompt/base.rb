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

          # One-time preamble telling the agent how to reach a tool these instructions name, whichever
          # way the host harness exposes it. Tool deferral is HOST-DEPENDENT: with tool search on, MCP
          # tools are absent until ToolSearch loads them; with it off (non-Anthropic models behind an
          # ANTHROPIC_BASE_URL proxy — see LauncherConfig) there is no ToolSearch and every MCP tool
          # sits in the active list already. So the rule leads with "look in your tool list and call
          # it", and only falls back to ToolSearch. An earlier version asserted unconditionally that
          # every MCP tool IS deferred; on ollama hosts that is false, and a triage child obeying it
          # hunted for a ToolSearch that does not exist and emitted status "error" — the very failure
          # the preamble exists to prevent. Whichever branch applies, "tool isn't available" is never
          # a reason to fail: the prompt's "On MCP failure: STOP" must not read as an outage.
          def tool_availability_note
            <<~NOTE.strip
              TOOL AVAILABILITY: when these instructions name a tool (e.g. ReadMcpResourceTool), FIRST look for it in your active tool list — if it is there, CALL IT DIRECTLY. Only if it is absent is it DEFERRED (schema not loaded yet), which is NOT missing and NOT an MCP failure: load it with ToolSearch query "select:<ToolName>" (e.g. "select:ReadMcpResourceTool"), THEN call it. If you have no ToolSearch tool, this host does not defer tools at all — re-read your tool list and call the named tool directly. NEVER substitute Bash for a tool you cannot find, and NEVER emit an error/failure status because a tool "isn't available".
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
