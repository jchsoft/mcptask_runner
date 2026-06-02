# frozen_string_literal: true

require_relative 'task_base'

module McptaskRunner
  module ClaudeCode
    class Triage
      module Prompt
        # Triage prompt when task_id is explicitly pinned.
        # Branch detection limited to checking whether a matching feature branch exists.
        class TaskPinned < TaskBase
          def initialize(task_id:)
            @task_id = task_id
          end

          private

          def branch_detection_step
            <<~STEP.strip
              STEP 1 - RESUME DETECTION:
              1. git branch --show-current
              2. Feature branch contains "#{@task_id}" → resuming=true
              3. On main/master:
                 a. git branch --list "*#{@task_id}*"
                 b. Match found → resuming=true
                 c. No match → resuming=false
              4. Other branch → resuming=false
              Task already set: #{@task_id}. Do NOT fetch different task.
            STEP
          end
        end
      end
    end
  end
end
