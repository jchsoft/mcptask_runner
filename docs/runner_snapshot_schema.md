# Runner Snapshot JSON Contract

**Schema version:** `3`

Shared contract between `mcptask_runner` (producer) and `mcptask.online` (consumer).
Neither side is modified without bumping `schema_version` — see [Changelog](#changelog)
for the fields that shipped without a bump anyway.

---

## Overview

The runner emits a single JSON snapshot per `(session, task)` pair whenever state changes.
The server persists the snapshot and broadcasts it as server-rendered HTML via Turbo Stream.
No individual events are streamed — only the snapshot hash.

---

## Top-level Schema

```json
{
  "schema_version": 3,
  "session_id":     "<uuid>",
  "machine_id":     "<hostname>",
  "project_name":   "McpTask rails runner",
  "task_id":        1234,
  "task_name":      "Fix login validation",
  "status":         "processing",
  "model":          "claude-sonnet-4-6",
  "active_actions": [ ... ],
  "thinking":       null,
  "message":        null,
  "todo_list":      [ ... ],
  "last_activity_at": "2026-05-18T10:30:00.123Z",
  "error_message":  null,
  "quota": {
    "per_day_hours":      8.0,
    "already_worked_hours": 3.2
  },
  "closed_at":  null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:30:00.456Z"
}
```

### Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `schema_version` | `Integer` | always | Server rejects unknown versions with a loud error. Current: `3`. |
| `session_id` | `String (UUID)` | always | Stable for the lifetime of one `EventStream` session. |
| `machine_id` | `String` | always | Hostname of the runner machine (`ENV["HOSTNAME"]` or `hostname`). |
| `project_name` | `String \| null` | always | Human-readable mcptask.online project name (resolved from `CLAUDE.md`). `null` if not resolved. Lets the web UI disambiguate runners on multi-project dashboards. |
| `task_id` | `Integer \| null` | always | `mcptask.online` piece `relative_id`. `null` during `starting`/`triage` before task is selected. |
| `task_name` | `String \| null` | always | Human-readable name fetched from triage result or piece lookup. `null` when `task_id` is `null`. |
| `status` | `String (enum)` | always | See [Status Enum](#status-enum) below. |
| `model` | `String \| null` | always | Claude model identifier (e.g. `"claude-sonnet-4-6"`). `null` before first executor starts. |
| `active_actions` | `Array<Action>` | always | Currently in-flight tool calls. Empty array when no tools running. See [Action Object](#action-object). |
| `thinking` | `String \| null` | always | Latest Claude thinking block, truncated to 500 chars. Self-expires to `null` after 30s of quiet so a stale thought never lingers. |
| `message` | `String \| null` | always | Latest non-thinking, non-tool text Claude said between tool calls, truncated to 500 chars. Self-expires to `null` after 60s of quiet. |
| `todo_list` | `Array<Todo>` | always | Mirror of the current `TodoWrite` list. Empty array when no todos. Each entry: `{ content: String, status: "pending" \| "in_progress" \| "completed", activeForm: String }`. |
| `last_activity_at` | `String (ISO 8601)` | always | Wall-clock timestamp of last stream event received from Claude. |
| `error_message` | `String \| null` | always | Non-null only when `status ∈ {stalled, frozen, error}`. |
| `quota` | `Object \| null` | when available | Nil when runner has no quota data (e.g. triage-only executors). |
| `quota.per_day_hours` | `Float` | when quota present | Daily hour budget. |
| `quota.already_worked_hours` | `Float` | when quota present | Hours already logged today before this session. |
| `closed_at` | `String (ISO 8601) \| null` | when closed | Set when `status = "closed"`. Tells UI when the row was closed. |
| `ttl_seconds` | `Integer \| null` | when closed | Seconds after `closed_at` before UI removes the row. Set when `status = "closed"`. |
| `updated_at` | `String (ISO 8601)` | always | Wall-clock when snapshot was built by runner. |

> **No `phase` field.** The `status` enum is sufficient — no legacy consumer remains.
>
> **No action history.** `active_actions` contains only currently running tools.
> Post-mortem of past tool calls lives in the local Claude session log, not the server DB.
> The last few *completed* actions on this task are kept runner-side (`SnapshotBuilder#recent_actions`,
> capped at 3) as a fresh-session-restart handoff hint — they are not part of the emitted snapshot.

---

## Status Enum

| Value | Meaning |
|-------|---------|
| `starting` | Session opened; runner initializing before triage. |
| `triage` | Triage executor running to select next task. |
| `processing` | Main task executor running (Claude working). |
| `waiting` | Between tasks: quota check, sleep, or idle loop. |
| `finished` | All tasks done; runner exiting cleanly. |
| `stalled` | `StallDetector` flagged spinning behaviour. Runner will retry with Opus escalation. |
| `frozen` | Server-side watchdog: no snapshot update for watchdog TTL. Runner may be dead. |
| `error` | Hard crash: context overflow, API overload, unhandled exception. |
| `closed` | Session ended (graceful or after error). `closed_at` + `ttl_seconds` set. Row fades from UI after TTL. |

---

## Status State Machine

```
                    ┌──────────┐
                    │ starting │
                    └────┬─────┘
                         │
                    ┌────▼─────┐
              ┌─────│  triage  │─────────────────────────┐
              │     └────┬─────┘                         │
              │          │ task found                    │ no tasks / quota
              │     ┌────▼──────┐                        │
              │     │ processing│◄─────────────┐         │
              │     └────┬──────┘              │         │
              │          │ task done           │ retry   │
              │     ┌────▼─────┐  more tasks   │         │
              │     │ waiting  │───────────────┘         │
              │     └────┬─────┘                         │
              │          │ all done                      │
              │     ┌────▼──────┐                        │
              │     │ finished  │◄───────────────────────┘
              │     └─────┬─────┘
              │           │
     error    │    ┌──────▼──────┐    error from any state
  (from any)  │    │   closed    │◄──────────────────────────┐
              └────►             │                           │
                   └─────────────┘                           │
                                                             │
              ┌──────────┐      ┌──────────┐      ┌─────────┴──┐
              │  stalled │─────►│  (retry) │      │   error    │
              └──────────┘      └──────────┘      └────────────┘
                   ▲                                     ▲
                   │  StallDetector fires                │ hard crash
                   │  (from processing)                  │ (from any)
                                                         │
              ┌────┴─────┐                               │
              │  frozen  │───────────────────────────────┘
              └──────────┘
                (server watchdog)
```

### Transition table

| From | To | Trigger |
|------|----|---------|
| `starting` | `triage` | Triage executor starts |
| `triage` | `processing` | Task selected, main executor starts |
| `triage` | `waiting` | No task found, sleeping |
| `triage` | `finished` | No more tasks, clean exit |
| `triage` | `error` | Triage executor crashed |
| `processing` | `waiting` | Task completed, loop continues |
| `processing` | `finished` | Last task done, loop exits |
| `processing` | `stalled` | `StallDetector` fires |
| `processing` | `error` | Context overflow / API overload / crash |
| `waiting` | `triage` | Woke up after sleep, finding next task |
| `waiting` | `finished` | Quota exhausted, graceful exit |
| `stalled` | `processing` | Retried with Opus escalation |
| `stalled` | `error` | Retry also failed |
| `any` | `frozen` | Server watchdog: no snapshot for N minutes |
| `any` | `closed` | `end_session` called, or frozen/error + server TTL |

---

## Action Object

Represents a single in-flight Claude tool call.

```json
{
  "tool_id":     "toolu_01XYZ",
  "name":        "Bash",
  "summary":     "bin/rails test test/models/user_test.rb",
  "description": null,
  "started_at":  "2026-05-18T10:29:45.000Z",
  "elapsed_s":   12
}
```

| Field | Type | Notes |
|-------|------|-------|
| `tool_id` | `String` | Claude tool use ID from stream JSON. |
| `name` | `String` | Tool name (e.g. `"Bash"`, `"Edit"`, `"Grep"`). |
| `summary` | `String` | Human-readable one-liner derived from tool input (truncated to 120 chars). |
| `description` | `String \| null` | Optional longer description of the tool call (truncated to 200 chars), when the tool call supplies one. `null` otherwise. |
| `started_at` | `String (ISO 8601)` | When the tool call began. |
| `elapsed_s` | `Integer` | Seconds elapsed since `started_at`, recomputed each snapshot. |

---

## Example Payloads

### `starting`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": null,
  "task_name": null,
  "status": "starting",
  "model": null,
  "active_actions": [],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:00:00.000Z",
  "error_message": null,
  "quota": null,
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:00:00.100Z"
}
```

### `triage`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": null,
  "task_name": null,
  "status": "triage",
  "model": "claude-haiku-4-5-20251001",
  "active_actions": [
    {
      "tool_id": "toolu_01TRIAGE",
      "name": "mcp__mcptask-online__ReadPieceTool",
      "summary": "pieces/jchsoft/@next?project_relative_id=7",
      "description": null,
      "started_at": "2026-05-18T10:00:02.000Z",
      "elapsed_s": 3
    }
  ],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:00:05.000Z",
  "error_message": null,
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 1.5
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:00:05.200Z"
}
```

### `processing`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "processing",
  "model": "claude-sonnet-4-6",
  "active_actions": [
    {
      "tool_id": "toolu_01BASH",
      "name": "Bash",
      "summary": "bin/rails test test/system/runner_sessions_test.rb",
      "description": null,
      "started_at": "2026-05-18T10:05:00.000Z",
      "elapsed_s": 47
    }
  ],
  "thinking": "Checking whether the system test covers the closed-row fade-out...",
  "message": null,
  "todo_list": [
    { "content": "Add schema_version to snapshot", "status": "completed", "activeForm": "Adding schema_version to snapshot" },
    { "content": "Write system test for Turbo morph", "status": "in_progress", "activeForm": "Writing system test for Turbo morph" }
  ],
  "last_activity_at": "2026-05-18T10:05:47.000Z",
  "error_message": null,
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 1.5
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:05:47.300Z"
}
```

### `waiting`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "waiting",
  "model": "claude-sonnet-4-6",
  "active_actions": [],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:20:00.000Z",
  "error_message": null,
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 3.0
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:20:00.500Z"
}
```

### `finished`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "finished",
  "model": "claude-sonnet-4-6",
  "active_actions": [],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:22:00.000Z",
  "error_message": null,
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 4.1
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:22:00.700Z"
}
```

### `stalled`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "stalled",
  "model": "claude-sonnet-4-6",
  "active_actions": [],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:15:00.000Z",
  "error_message": "Stall detected: reason=edit_failure_streak signature=Edit:SAME_FILE count=5",
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 2.8
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:15:01.000Z"
}
```

### `frozen`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "frozen",
  "model": "claude-sonnet-4-6",
  "active_actions": [
    {
      "tool_id": "toolu_01STUCK",
      "name": "Bash",
      "summary": "bin/rails test:system",
      "description": null,
      "started_at": "2026-05-18T10:10:00.000Z",
      "elapsed_s": 3600
    }
  ],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:10:00.000Z",
  "error_message": "No snapshot update for 10 minutes — runner may be dead",
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 2.0
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:20:00.000Z"
}
```

> **Note:** `frozen` is set by the **server-side watchdog**, not by the runner. The runner cannot
> emit `frozen` because it is dead. The server flips the status after detecting stale `updated_at`.

### `error`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "error",
  "model": "claude-sonnet-4-6",
  "active_actions": [],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:18:00.000Z",
  "error_message": "ContextOverflowError: Prompt is too long",
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 3.5
  },
  "closed_at": null,
  "ttl_seconds": null,
  "updated_at": "2026-05-18T10:18:01.000Z"
}
```

### `closed`

```json
{
  "schema_version": 3,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "machine_id": "karelmracek-mbp",
  "project_name": "McpTask rails runner",
  "task_id": 10356,
  "task_name": "Define runner snapshot JSON contract",
  "status": "closed",
  "model": "claude-sonnet-4-6",
  "active_actions": [],
  "thinking": null,
  "message": null,
  "todo_list": [],
  "last_activity_at": "2026-05-18T10:22:00.000Z",
  "error_message": null,
  "quota": {
    "per_day_hours": 8.0,
    "already_worked_hours": 4.1
  },
  "closed_at": "2026-05-18T10:22:05.000Z",
  "ttl_seconds": 30,
  "updated_at": "2026-05-18T10:22:05.100Z"
}
```

---

## Server Behaviour Notes

1. **Schema version check** — if `schema_version` is unknown, server logs an error and drops the snapshot. No silent failures.
2. **Snapshot persistence** — hot state (non-closed) stored in Solid Cache / Redis. Only `closed` entries written to Postgres for timeline history.
3. **Broadcast** — snapshot rendered via `RunnerSessionPresenter` + Slim partial → HTML → Turbo Stream morph to correct DOM ID.
4. **Turbo morph** — use `morph` (not `replace`) for row updates at ~2 Hz to prevent flicker / focus loss / scroll reset.
5. **Dead-runner watchdog** — periodic server job flips stale snapshots (`updated_at` older than N minutes, status not `closed`) to `frozen`. Covers hard runner crashes where no `closed` event reaches the server.
6. **UI fade-out** — when `status = "closed"`, UI starts a countdown from `ttl_seconds` then removes the row.
7. **Frozen UI** — when `status = "frozen"`, row stays visible with orange background and yellow error message on red background.

---

## Runner Emission Notes

1. Runner builds snapshot from internal state (`SnapshotBuilder`) — no per-tool events sent to server.
2. Snapshot emitted on every state change (status transition, tool start/finish, heartbeat).
3. Throttled to max 2 Hz at the `EventStream` layer to avoid flooding the ActionCable connection.
4. `active_actions` built from current `@active_tool_calls` hash; `elapsed_s` computed at snapshot build time.
5. `last_activity_at` derived from monotonic clock converted to wall-clock ISO 8601.

---

## Changelog

| Version | Added | Notes |
|---------|-------|-------|
| `1` | `schema_version`, `session_id`, `machine_id`, `task_id`, `task_name`, `status`, `model`, `active_actions` (`tool_id`, `name`, `summary`, `started_at`, `elapsed_s`), `last_activity_at`, `error_message`, `quota`, `closed_at`, `ttl_seconds`, `updated_at` | Initial contract (#10358). |
| `2` | `thinking`, `active_actions[].description` | Surfaces Claude's current thinking block and an optional longer per-tool description. |
| `3` | `project_name` | Human-readable project name for multi-project dashboards. |

Two fields shipped as backwards-compatible additions **without** a version bump — a consumer that
ignores unknown keys already handles them correctly, but they are called out here so a
version-pinned consumer knows what it silently misses:

- `todo_list` (`Array<Todo>`, always present, empty array when no todos) — mirror of the current
  `TodoWrite` list. Added under `schema_version 1`.
- `message` (`String | null`) — latest non-thinking, non-tool text Claude said between tool calls.
  Added under `schema_version 2`.

A consumer pinned to `schema_version 1` receives `thinking`, `active_actions[].description`,
`todo_list`, `message`, and `project_name` in every payload emitted by a current runner — it just
does not know to expect them, since the runner does not gate emission on the consumer's declared
version. Rely on the version bump for *breaking* changes; treat any key not in your version's table
as optional and ignore it.
