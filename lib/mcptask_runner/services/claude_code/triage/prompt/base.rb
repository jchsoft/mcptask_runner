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
        end
      end
    end
  end
end
