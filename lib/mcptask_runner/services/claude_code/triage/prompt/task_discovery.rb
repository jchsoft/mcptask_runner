# frozen_string_literal: true

require_relative 'task_base'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Triage prompt when neither task_id nor story_id is given.
        # Resolves task via branch/PR detection or falls through to @next.
        class TaskDiscovery < TaskBase
          def initialize(project_id:, ignore_quota:)
            super(ignore_quota: ignore_quota)
            @project_id = project_id
            @task_id = nil
          end

          private

          def project_relative_id
            @project_id
          end

          def fetch_step_suffix
            ' (unless STEP 1c override)'
          end

          def branch_detection_step
            <<~STEP.strip
              STEP 1 - RESUME DETECTION:
              1. git branch --show-current
              2. main/master → STEP 2, resuming=false
              3. Feature branch:
                 a. Extract 4+ digit task ID from branch (e.g. "feature/9508-..." → 9508)
                 b. No ID → check PR: gh pr list --head $(git branch --show-current) --json body --jq '.[0].body'
                    Look for mcptask.online link → extract task ID
                 c. Found → use this {task_id} in STEP 2 (mcptask://pieces/#{account_code}/{task_id}), resuming=true
                 d. Not found → STEP 2, resuming=false
            STEP
          end
        end
      end
    end
  end
end
