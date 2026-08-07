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

              HIGH-OUTPUT OVERRIDE: if the deliverable is a LOT of GENERATED TEXT rather than a small targeted change → recommended_model="genius". Signals: landing/marketing page copy, multi-section page rewrite, docs, or ANY task touching 2+ locale files (a cs/en/sk change writes every block three times). Generated output fills the context window exactly like input does, so these die of context overflow on a smaller model even when the logic is trivial. Beats the DURATION HINT below.

              "primitive": trivial — typo fix, single CSS change, one-line config

              "genius" ONLY: UI elements/improvements/beautification, complex architecture (models+associations, multi-service, migrations w/ data transforms), security (auth/encryption), ambiguous requirements, Story type, FIXING FAILING TESTS / debugging test failures (red→green, flaky tests, CI-failing specs — Sonnet historically struggles here)

              "smart" (DEFAULT): everything else — CRUD, refactoring, bug fixes, writing NEW tests, simple frontend, validations/scopes/callbacks, single-locale key tweaks / config / short docs, API endpoints

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
              TOOL AVAILABILITY: when these instructions name a tool (e.g. ReadMcpResourceTool), CALL IT DIRECTLY — that is the first and normally the only route. Two host shapes, decide by whether YOU have a ToolSearch tool: (a) no ToolSearch tool → this host defers nothing, the named tool is live, call it directly; (b) ToolSearch exists and the named tool is only NAMED somewhere without a schema → it is DEFERRED, which is NOT missing and NOT an MCP failure: load it with ToolSearch query "select:<ToolName>" (e.g. "select:ReadMcpResourceTool"), THEN call it. NEVER substitute Bash/curl for a tool you cannot find, and NEVER emit an error/failure status because a tool "isn't available".
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
