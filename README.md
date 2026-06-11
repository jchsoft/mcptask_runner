# mcptask_runner

A Ruby gem that adds rake tasks to a host Rails application for automated execution of [mcptask.online](https://mcptask.online) tasks by Claude Code. It orchestrates the full lifecycle of agentic work — discovering tasks, triaging complexity, selecting the right model tier, spawning Claude Code, supervising the run with a heartbeat watchdog and stall detector, guarding the daily quota, and (optionally) auto-merging the resulting PR after CI — while streaming a live snapshot of runner state back to mcptask.online and recording structured per-run logs for diagnosis.

## Requirements

- Ruby `>= 3.0`
- Rails `>= 6.0`
- `websocket-client-simple` `~> 0.7`
- The Claude Code CLI on `PATH` (or an alternate backend, see [Configuration](#configuration))
- An mcptask.online account and API token

## Installation

Add the gem to your host Rails app's `Gemfile`:

```ruby
gem "mcptask_runner", git: "git@github.com:jchsoft/mcptask_runner.git"
```

Then install:

```bash
bundle install
```

Run the installer to provision skills, permissions, tokens, MCP config, and (on macOS) a scheduled LaunchAgent:

```bash
bundle exec rake mcptask_runner:install
```

The install flow performs the following steps in order:

1. **Install skills** — copies the 11 bundled Claude Code skills from the gem into `.claude/skills/` (skips existing ones unless `FORCE=1`). A manifest tracks each skill's content hash so updates can be detected later.
2. **Check helper binaries** — verifies `ci_wait`, `ci_start`, `test_start`, `test_lock`, and `run_with_log` exist in `~/.claude/bin` (warns if missing).
3. **Sync permissions** — merges the gem's `baseline_permissions.json` into `.claude/settings.local.json`.
4. **Provision tokens** — obtains a JWT for mcptask.online and writes it to `~/.mcptask_env.d/mcptask_token`, sourcing that directory from `~/.zshrc`.
5. **Configure `.mcp.json`** — adds the `mcptask-online` SSE server entry.
6. **Generate LaunchAgent** — macOS only; sets up weekday (Mon–Fri) scheduling at 08:00.

> **Helper binaries** (`ci_wait`, `ci_start`, `test_start`, `test_lock`, `run_with_log`) are **not created by the installer** — they must already be present in `~/.claude/bin` for the CI/test skills to work.

### `.mcp.json` and tokens

The installer adds an `mcptask-online` SSE entry to `.mcp.json`:

```json
{
  "mcpServers": {
    "mcptask-online": {
      "type": "sse",
      "url": "https://mcptask.online/mcp/sse",
      "headers": { "Authorization": "Bearer ${MCPTASK_TOKEN}" }
    }
  }
}
```

The token is provisioned by authenticating to mcptask.online. Credentials are read from `MCPTASK_EMAIL` / `MCPTASK_PASSWORD` env vars, or prompted interactively if running in a TTY. The resulting JWT is written to `~/.mcptask_env.d/mcptask_token` as a shell export, and `~/.zshrc` is updated to source everything in `~/.mcptask_env.d/*`.

The same token is reused for the REST quota API and the snapshot stream — both resolve it from the `.mcp.json` `Authorization` header (supporting `${VAR}` templates or a literal Bearer value) or fall back to the `MCPTASK_TOKEN` env var.

## Configuration

### `config/models.yml` — spice levels

The runner maps three "spice levels" to concrete model IDs. Copy `config/models.yml.example` to `config/models.yml` and pin versioned IDs:

```yaml
genius:    claude-opus-4-8
smart:     claude-sonnet-4-6
primitive: claude-haiku-4-5-20251001
```

- **genius** — heavy coding executors (Honest, the auto-squash family, manual task/story).
- **smart** — Triage and Review/Reviews.
- **primitive** — read-only Dry display.

Pinning versioned IDs prevents context-overflow retry chains. The runner also exports these as `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` so forked subagents and skills inherit the same overrides. `models.yml` is **optional**: without it the runner falls back to generic `opus`/`sonnet`/`haiku` aliases that the Claude CLI resolves at runtime. On non-Anthropic backends you **must** pin all three IDs or forked subagents fail with "model may not exist". The file is gitignored — each host keeps its own copy.

### `config/launcher.yml` — alternate backend

Copy `config/launcher.yml.example` to `config/launcher.yml` to override the default `claude` CLI launcher:

```yaml
command: [ollama, launch, claude]
```

The `command` value (array or string) replaces the launcher prefix; the runner still appends its own flags (`-p`, `--model`, `--output-format=stream-json`, `--verbose`, etc.). The model still comes from `config/models.yml`. Also optional — without it the runner autodetects the `claude` binary (or uses `$CLAUDE_PATH`).

### Environment variables

| Variable | Effect |
|----------|--------|
| `MCPTASK_TOKEN` | mcptask.online API token (fallback when not in `.mcp.json`) |
| `MCPTASK_EMAIL` / `MCPTASK_PASSWORD` | Credentials for token provisioning |
| `MCPTASK_RUNNER_DISABLE` | Kill switch for the EventStream snapshot WebSocket |
| `MCPTASK_RUN_LOG=0` | Disable per-run JSON log writes (used in tests) |
| `FORCE=1` | Bypass existence checks during install/update |
| `verbose=true` | Verbose rake task output (default: normal) |
| `ignore_quota=true` | Skip quota checks on a run |

## Usage

All tasks are invoked with `bundle exec rake <task>`. Pass `verbose=true` for verbose output and `ignore_quota=true` to bypass quota checks where supported.

### Manual modes

PRs are created and left **open for human review** (no auto-merge).

| Task | What it does |
|------|--------------|
| `mcptask_runner:manual:once` | Triage and execute a single task. |
| `mcptask_runner:manual:once_dry` | Dry run — loads and displays the next task only; no execution, no PR. |
| `mcptask_runner:manual:today` | Loop tasks until end of today. |
| `mcptask_runner:manual:daily` | Continuous daily loop (runs indefinitely, re-scheduling each day). |
| `mcptask_runner:manual:queue` | Process the task queue continuously; PRs stay open for review. |
| `mcptask_runner:manual:review` | Fix human review feedback on the current branch's PR (single PR). |
| `mcptask_runner:manual:reviews` | Loop over all PRs with unaddressed reviews until none remain. |
| `mcptask_runner:manual:workflow` | Process reviews first, then run today's tasks. |
| `mcptask_runner:manual:story[STORY_ID]` | Execute all tasks in a Story; PRs left open. Requires `STORY_ID`. |
| `mcptask_runner:manual:task[TASK_ID]` | Execute one specific task; PR left open. Requires `TASK_ID`. |

### Auto-squash modes

PRs are **automatically squash-merged after CI passes**.

| Task | What it does |
|------|--------------|
| `mcptask_runner:auto:once` | Single task, auto-merge after CI, then exit. |
| `mcptask_runner:auto:squash:today` | Loop today's tasks with auto-merge (quota-limited). |
| `mcptask_runner:auto:squash:story[STORY_ID]` | Execute all Story tasks with auto-merge. Requires `STORY_ID`. |
| `mcptask_runner:auto:squash:task[TASK_ID]` | Execute one specific task with auto-merge. Requires `TASK_ID`. |
| `mcptask_runner:auto:squash:queue` | Continuous queue mode with auto-merge (pass `ignore_quota=true` to skip quota checks). |

### Maintenance

| Task | What it does |
|------|--------------|
| `mcptask_runner:install` | Install skills, permissions, tokens, `.mcp.json`, and LaunchAgent (macOS). `FORCE=1` to overwrite. |
| `mcptask_runner:update` | Refresh bundled skills after a gem update, preserving local edits. `FORCE=1` to back up and overwrite modified skills. |
| `mcptask_runner:prepare:permissions` | Merge baseline permissions into `.claude/settings.local.json` and print a report. |
| `mcptask_runner:bug_report` | Prompt for title/description and create a high-priority bug piece on mcptask.online with the latest run log and redacted env configs attached. |

> Story and task tasks **require** their argument and raise `ArgumentError` if `STORY_ID` / `TASK_ID` is missing or non-positive.

## How it works

### WorkLoop and its concerns

`WorkLoop` is the orchestrator. It initializes the EventStream session, dispatches to a mode-specific `run_*` method, handles crashes, and always closes the snapshot. Its behavior is split across three concerns:

- **TriageExecution** — runs Triage to assess complexity and pick a model tier, detects Story vs. Task from the queue, maps each parent executor to its child variant, upgrades `smart → genius` on resume, manages branch checkout, and bypasses triage entirely for pinned urgent bugs.
- **QuotaScheduling** — delegates the overall stop decision to the Decider, enforces end-of-day / end-of-workday time gates, drives the DailyScheduler / WaitingStrategy pause-and-retry loops, and handles "no tasks available" waits.
- **LoopStrategies** — implements every iteration pattern: single (`run_once`, `run_once_dry`, `run_review`, the `*_auto_squash` and `task_*` singles), multi-task (`run_reviews`, `run_workflow`, `run_today`, `run_daily`), story, and queue loops.

### Executor family

All executors descend from `ClaudeCodeBase`, which orchestrates instruction building → command construction → `Open3.popen3` spawn → streaming threads → result parsing → retry. Its concerns handle process lifecycle (SIGTERM/SIGKILL with grace), real-time stream parsing, `TASKRUNNER_RESULT` marker extraction, prompt-fragment building, retry state, and heartbeat monitoring.

| Executor | Role | Tier |
|----------|------|------|
| `Triage` | Analyze complexity, recommend tier; no edits | smart |
| `Honest` | Core work: branch, code, tests, PR | genius |
| `Dry` | Read-only display of the next task | primitive |
| `Review` / `Reviews` | Fix PR review feedback (single / loop) | smart |
| `TaskManual` / `StoryManual` | Specific task / Story tasks, PR left open | genius |
| `TaskAutoSquash` / `StoryAutoSquash` | Specific task / Story with auto-merge | genius |
| `TodayAutoSquash` / `QueueAutoSquash` / `OnceAutoSquash` | Queue/today/single with auto-merge | genius |
| `AutoSquashBase` | Shared auto-merge logic: preflight merged-PR match, post-merge recovery | — |

### Supporting subsystems

- **Triage** routes work: a `Story` piece triggers the story-loop variant of the executor; an active urgent pin skips discovery and runs the bug directly as a Task executor on genius.
- **Decider** makes the between-task stop decision (failed tasks, mid-task quota kill, daily quota exceeded) and returns a summary of remaining hours and tasks completed/failed.
- **QuotaGuard** is the single source of truth for the daily quota — REST-only via `TimeStatusClient` against `/api/{account}/users/current/time_status`, comparing worked-today against the per-day budget. It is **fail-closed**: a persistent REST error is treated as quota-exceeded so the runner stops rather than risk a silent overrun. It gates the pre-run check, the between-task loops, and the mid-task heartbeat.
- **DailyScheduler** decides whether work can happen today and whether to keep working between tasks; `can_work_today?` is fail-open to avoid condemning a whole day to a transient REST blip.
- **HeartbeatMonitoring** runs a watchdog thread: inactivity kill at 1200s (20 min), a `frozen` soft-warn at 180s, per-tool hang ceilings (quick tools warn 120s / kill 300s, long-running Bash/Task/Skill warn 600s / kill 1500s), an absolute-silence backstop at 1800s, and a periodic REST quota re-poll. It refreshes the RunLog on each beat.
- **StallDetector** is fed the stream line-by-line and detects spinning (repeated Edit/Bash failures or the same tool signature repeating with no file mutations). Polling helpers (`ci-wait`, `test-wait`, `wait-unlock`) are excluded. On a stall it kills the subprocess; the task stays `in_progress` and the next triage resumes it forced to Opus.
- **UrgentBugPin** persists an urgent bug `task_id` to disk so a restart targets the bug instead of cycling the queue.
- **EventStream + SnapshotBuilder** broadcast live runner state over a WebSocket to mcptask.online. `SnapshotBuilder` is a thread-safe state machine with an explicit status FSM (`starting → triage → processing → waiting → finished / stalled / frozen / pending / error / closed`) and an immutable snapshot hash; emission is throttled. The stream is disabled when `MCPTASK_RUNNER_DISABLE` is set or no token/cable URL resolves.

## Bundled skills

The installer copies these skills into `.claude/skills/`:

| Skill | Context | Purpose |
|-------|---------|---------|
| `memory-search` | Haiku fork | Search LLM Memory Notes, return a compact filtered summary |
| `discover` | Haiku fork | Locate symbols/callers/impact via CodeGraph → LSP → Grep |
| `mcptask-read` | Haiku fork | Fetch piece/task data as a compact summary |
| `mcptask-write` | parent | Create pieces, log progress, attach files (needs returned IDs) |
| `test-runner` | parent | Orchestrate `test-start` + `test-wait` with adaptive timeouts |
| `test-start` | Haiku fork | Acquire global test lock, launch detached test command |
| `test-wait` | Haiku fork | Poll the test log for an exit-code footer (≤9 min) |
| `ci-runner` | parent | Orchestrate `ci-start` + `ci-wait` for `bin/ci` under a global lock |
| `ci-start` | Haiku fork | Acquire global CI lock, launch `bin/ci` detached |
| `ci-wait` | Haiku fork | Poll the CI log for an exit-code footer (≤9 min) |
| `wait-unlock` | Haiku fork | Wait for the global test lock to release |

## Observability

- **Per-run state** — `log/runs/run_*.json` (RunLog). A structured JSON record per execution attempt: session/task/model/executor/pid metadata, live status, active actions, stream-event count, inactivity timers, termination reason, elapsed seconds, and the parsed result (status, PR number, branch). Refreshed every heartbeat. **Start here for hung-run triage** instead of grepping the raw stream. Disable with `MCPTASK_RUN_LOG=0`. Writes are best-effort and never crash a run.
- **Raw stream** — `log/mcptask_runner_YYYYMMDD_HHMMSS.log`, the full Claude Code stream for a run. (When launched via the LaunchAgent, rake stdout is additionally redirected to `~/logs/mcptask_runner/<slug>.log`.)
- **Snapshot streaming** — `EventStream` pushes throttled `SnapshotBuilder` frames to mcptask.online, which persists and renders them as a live web card via Turbo Stream. The producer/consumer contract lives in `docs/runner_snapshot_schema.md` (schema version `1`) — neither side changes without bumping the version.
- **Bug report** — `rake mcptask_runner:bug_report` creates a high-priority bug piece with the most recent run log and your env configs (`.mcp.json`, `.claude/settings*.json`) attached, with tokens redacted. Note: the attached run log itself is **not** redacted — inspect it before filing a public bug.

## Updating the gem

After bumping the gem version, refresh the bundled skills:

```bash
bundle exec rake mcptask_runner:update
```

Update classifies each skill as missing (copy), identical (skip), outdated (update), or locally modified (warn, or back up to `*.bak` and overwrite with `FORCE=1`), so your local edits are preserved by default.

> The gem version is auto-incremented by the `post-merge` git hook when `lib/` files change — do not run `bin/increment_version.rb` manually. Install hooks with `bin/install-hooks`.

### Developing the skills themselves

`config/skills/` is the source of truth for the 11 bundled skills. To make them loadable by Claude while working **on this repo**, they are synced into the repo's own `.claude/skills/` (gitignored — never edit there, edit `config/skills/`):

```bash
ruby bin/sync-skills        # copy config/skills/* → .claude/skills/* (idempotent)
```

This runs automatically via git hooks (installed by `bin/install-hooks`): the `post-merge` hook re-syncs whenever a pull touches `config/skills/`, and the `post-checkout` hook syncs on clone or branch switch.

## Testing

```bash
ruby test_runner.rb        # tests only
ruby bin/ci                # full CI: tests + RuboCop + Reek + Flay
```

Individual test files:

```bash
ruby -I lib -I test test/services/work_loop_test.rb
```

All checks must pass before committing.

## License

MIT
