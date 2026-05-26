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

          def initialize(ignore_quota:)
            @ignore_quota = ignore_quota
          end

          def build
            raise NotImplementedError, "#{self.class} must implement #build"
          end

          private

          def daily_quota_check_step
            @ignore_quota ? quota_skipped_step : quota_active_step
          end

          def quota_skipped_step
            <<~STEP.strip
              STEP 0 - DAILY QUOTA (SKIPPED — ignore_quota=true):
              1. Read mcptask://user (server="mcptask-online"). Extract "hour_goal" + "worked_out" for hours block. Never STOP on quota.
              2. Always proceed to STEP 1 regardless of worked_out vs hour_goal.
            STEP
          end

          def quota_active_step
            <<~STEP.strip
              STEP 0 - DAILY QUOTA (FIRST — MUST USE TOOL):
              1. INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://user".
                 This is a TOOL CALL, not text. You MUST emit a tool_use block before any JSON output.
                 DO NOT GUESS. DO NOT WRITE TASKRUNNER_RESULT until you have received the tool result.
                 If you output JSON without first calling this tool, the result is INVALID and rejected.
                 Extract "hour_goal" → per_day. "worked_out" → already_worked.
                 per_day=0 is VALID (holiday/non-working day), keep the 0. Only null=failure → retry tool call.
              2. worked_out >= hour_goal → STOP. TASKRUNNER_RESULT:
                 status="quota_exceeded", recommended_model="genius", task_id=0, resuming=false
                 hours: {per_day: <hour_goal>, task_estimated: 0, already_worked: <worked_out>}
              3. worked_out < hour_goal → STEP 1
            STEP
          end

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

          def triage_hours_instruction(entity:, status_entries:)
            <<~INSTRUCTION.strip
              Hours:
              1. per_day = "hour_goal" (from STEP 0)
              2. already_worked = "worked_out" (from STEP 0)
              3. task_estimated = "duration_best" from #{entity} (e.g. "30 minut"→0.5, "1 hodina"→1.0)
              4. Status:
                 #{status_entries}
            INSTRUCTION
          end
        end
      end
    end
  end
end
