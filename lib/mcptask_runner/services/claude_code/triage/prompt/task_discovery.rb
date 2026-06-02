# frozen_string_literal: true

require_relative 'task_base'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Triage prompt when neither task_id nor story_id is given.
        # Resolves task via branch/PR detection or falls through to @next.
        class TaskDiscovery < TaskBase
          def initialize(project_id:)
            @project_id = project_id
            @task_id = nil
          end

          private

          def project_relative_id
            @project_id
          end

          def fetch_step_suffix
            ''
          end

          def branch_detection_step
            <<~STEP.strip
              STEP 1 - NO BRANCH RESUME:
              Always fetch next task from @next (STEP 2). resuming=false.
              Branch-based task discovery is disabled: a sitting feature branch must never reroute work away from @next priority order.
            STEP
          end
        end
      end
    end
  end
end
