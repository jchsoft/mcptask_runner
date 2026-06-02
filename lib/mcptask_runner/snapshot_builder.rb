# frozen_string_literal: true

module McptaskRunner
  # Holds complete per-session runner state and builds the snapshot Hash
  # consumed by EventStream. Thread-safe: both the main executor thread and
  # the heartbeat thread call into this object concurrently.
  #
  # Durations use monotonic clock internally; wall-clock only for ISO 8601
  # timestamp fields (last_activity_at, updated_at, started_at, closed_at).
  class SnapshotBuilder
    SCHEMA_VERSION = 2

    # Latest thinking block self-expires after this many seconds of quiet, so a
    # stale thought never lingers in the snapshot once Claude moves on.
    THINKING_TTL_S = 30

    # Text message from Claude (non-thinking, non-tool text) self-expires after
    # this many seconds so old messages don't persist into the next work cycle.
    MESSAGE_TTL_S = 60

    # Latest thought + its monotonic stamp, bundled so build_snapshot can age it out.
    Thought = Data.define(:text, :mono_at)

    # Latest text message from Claude (between tool calls), same shape as Thought.
    Message = Data.define(:text, :mono_at)

    # End-of-session tombstone: when the session closed + how long the server keeps it.
    Tombstone = Data.define(:closed_at, :ttl_seconds)

    VALID_STATUSES = %w[starting triage processing waiting finished stalled frozen error closed].freeze

    # Explicit allowed transitions per task #10358 spec.
    # Additionally: any → frozen (server watchdog), any → closed (end_session).
    # processing → triage: loop iterations skipping finished (story loop, executor crashed
    # before its finished-transition guard). Without it, FSM rejects legitimate loop resets.
    TRANSITIONS = {
      "starting"   => %w[triage processing waiting error],
      "triage"     => %w[processing waiting triage error],
      "processing" => %w[waiting finished stalled frozen pending triage error],
      "waiting"    => %w[processing triage finished error],
      "stalled"    => %w[processing triage error closed],
      "frozen"     => %w[processing triage error closed pending],
      "pending"    => %w[processing triage error closed frozen],
      "finished"   => %w[closed waiting triage],
      "error"      => %w[closed triage],
      "closed"     => []
    }.freeze

    def initialize(session_id:, machine_id:)
      @mutex = Mutex.new
      @session_id = session_id
      @machine_id = machine_id
      @task_id = nil
      @task_name = nil
      @status = "starting"
      @model = nil
      @quota = nil
      @error_message = nil
      @active_actions = {}
      @todos = []
      @thought = nil
      @message = nil
      @tombstone = nil
      @last_activity_at = Time.now.utc
    end

    def set_task(task_id:, task_name: nil)
      @mutex.synchronize do
        @task_id = task_id
        @task_name = task_name
        @todos = [] # prior task's TodoWrite must not leak into next task
        @thought = nil # nor prior task's last thought
        @message = nil # nor its last text message
        touch_activity
      end
    end

    def set_status(status, error_message: nil)
      status = status.to_s
      @mutex.synchronize do
        assert_valid_transition(@status, status)
        @status = status
        @error_message = error_message
        touch_activity
      end
    end

    def set_model(model)
      @mutex.synchronize do
        @model = model
        touch_activity
      end
    end

    def set_quota(per_day_hours:, already_worked_hours:)
      @mutex.synchronize do
        @quota = { per_day_hours: per_day_hours.to_f, already_worked_hours: already_worked_hours.to_f }
        touch_activity
      end
    end

    # Update the todo list snapshot from a TodoWrite tool input.
    # Each entry is normalized to { content, status, activeForm }.
    # Empty / nil input clears the list.
    def set_todos(todos)
      @mutex.synchronize do
        @todos = Array(todos).map { |t| normalize_todo(t) }.compact
        touch_activity
      end
    end

    def tool_started(tool_id:, name:, summary:, description: nil)
      @mutex.synchronize do
        @active_actions[tool_id] = {
          name: name,
          summary: summary.to_s[0, 120],
          description: description&.to_s&.slice(0, 200),
          mono_started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
          started_at: Time.now.utc.iso8601(3)
        }
        touch_activity
      end
    end

    # Latest thinking block. Stored with a monotonic stamp so build_snapshot can
    # drop it once stale (see current_thinking). Callers pass '...' for redacted thoughts.
    def set_thinking(text)
      text = text.to_s.strip
      return if text.empty?

      @mutex.synchronize do
        @thought = Thought.new(text: text[0, 500], mono_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        touch_activity
      end
    end

    # Text message Claude outputs between tool calls. Stored with a monotonic stamp
    # so build_snapshot can age it out (see current_message). Empty text skipped.
    def set_message(text)
      text = text.to_s.strip
      return if text.empty?

      @mutex.synchronize do
        @message = Message.new(text: text[0, 500], mono_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        touch_activity
      end
    end

    def tool_finished(tool_id:)
      @mutex.synchronize do
        @active_actions.delete(tool_id)
        touch_activity
      end
    end

    def clear_active_actions
      @mutex.synchronize do
        @active_actions.clear
        touch_activity
      end
    end

    def mark_activity
      @mutex.synchronize { touch_activity }
    end

    def close(ttl_seconds: 60)
      @mutex.synchronize do
        @status = "closed"
        @tombstone = Tombstone.new(closed_at: Time.now.utc.iso8601(3), ttl_seconds: ttl_seconds)
        @error_message = nil
        @active_actions.clear
        @thought = nil
        @message = nil
        touch_activity
      end
    end

    def to_h
      @mutex.synchronize { build_snapshot }
    end

    def status
      @mutex.synchronize { @status }
    end

    def has_active_tools?
      @mutex.synchronize { @active_actions.any? }
    end

    def active_tool_count
      @mutex.synchronize { @active_actions.size }
    end

    def active_tool_names
      @mutex.synchronize { @active_actions.values.map { |a| a[:name] } }
    end

    def active_actions_snapshot
      @mutex.synchronize { @active_actions.dup }
    end

    def format_active_tools(now = nil)
      @mutex.synchronize do
        return '' if @active_actions.empty?

        now_val = now || Process.clock_gettime(Process::CLOCK_MONOTONIC)
        tools = @active_actions.map do |_id, info|
          duration = (now_val - info[:mono_started_at]).to_i
          "#{info[:name]} since #{duration}s"
        end
        ", waiting for: #{tools.join(', ')}"
      end
    end

    private

    def touch_activity
      @last_activity_at = Time.now.utc
    end

    def build_snapshot
      now_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      {
        schema_version:   SCHEMA_VERSION,
        session_id:       @session_id,
        machine_id:       @machine_id,
        task_id:          @task_id,
        task_name:        @task_name,
        status:           @status,
        model:            @model,
        active_actions:   build_active_actions(now_mono),
        thinking:         current_thinking(now_mono),
        message:          current_message(now_mono),
        todo_list:        @todos.dup,
        last_activity_at: @last_activity_at.iso8601(3),
        error_message:    @error_message,
        quota:            @quota ? { per_day_hours: @quota[:per_day_hours], already_worked_hours: @quota[:already_worked_hours] } : nil,
        closed_at:        @tombstone&.closed_at,
        ttl_seconds:      @tombstone&.ttl_seconds,
        updated_at:       Time.now.utc.iso8601(3)
      }.freeze
    end

    def build_active_actions(now_mono)
      @active_actions.map do |tool_id, action|
        elapsed = (now_mono - action[:mono_started_at]).round
        {
          tool_id:     tool_id,
          name:        action[:name],
          summary:     action[:summary],
          description: action[:description],
          started_at:  action[:started_at],
          elapsed_s:   elapsed
        }
      end
    end

    def current_thinking(now_mono)
      return nil unless @thought
      return nil if (now_mono - @thought.mono_at) > THINKING_TTL_S

      @thought.text
    end

    def current_message(now_mono)
      return nil unless @message
      return nil if (now_mono - @message.mono_at) > MESSAGE_TTL_S

      @message.text
    end

    def normalize_todo(todo)
      h = todo.is_a?(Hash) ? todo.transform_keys(&:to_s) : nil
      return nil unless h && h['content']

      {
        content:    h['content'].to_s[0, 200],
        status:     normalize_todo_status(h['status']),
        activeForm: h['activeForm'].to_s[0, 200]
      }
    end

    def normalize_todo_status(status)
      s = status.to_s
      %w[pending in_progress completed].include?(s) ? s : 'pending'
    end

    def assert_valid_transition(from, to)
      return if to == "frozen" # any → frozen: server watchdog can always freeze
      return if to == "pending" # any → pending: hung-tool watchdog always allowed
      return if to == "stalled" # any → stalled: StallDetector watchdog always allowed
      return if to == "closed" # any → closed: end_session always allowed

      allowed = TRANSITIONS.fetch(from, [])
      return if allowed.include?(to)

      raise InvalidTransitionError, "Invalid status transition: #{from.inspect} → #{to.inspect}"
    end
  end

  Error = Class.new(StandardError) unless const_defined?(:Error)
  class InvalidTransitionError < Error; end
end
