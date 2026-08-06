## Project-specific lookup hints

Generic exploration order (Memory → `/discover` → CodeGraph → LSP → Read → Grep) and skill-first MCP rules live in `~/.claude/CLAUDE.md`. mcptask-runner gotchas:

- **Concerns / namespace modules** (`InstructionBuilding`, `RetryHandling`, `StreamProcessing`, `UrgentBugPin`, etc.) — CodeGraph won't index them. Use `/discover` (handles the Ruby `module` caveat) or LSP `documentSymbol` on the concern file.

## LLM Memory Notes MCP Usage
- Memory identifier: `wv-runner` (architecture, patterns, commands, testing info)

## mcptask.online
- Project name: "McpTask rails runner"
- project_relative_id=69
- account_code: `jchsoft`

## CI & Quality Checks
- **Full CI**: `ruby bin/ci` — all checks (tests, RuboCop, Reek, Flay)
- **Tests only**: `ruby test_runner.rb`
- **Individual tests**: `ruby -I lib -I test test/services/<test_file>.rb`
- **All checks must pass before commit**

## Logs
- **Per-run state** (start here for hung runs): `log/runs/run_*.json` — `RunLog`, refreshed per heartbeat. Off: `MCPTASK_RUN_LOG=0`.
- **Context-overflow handoff** (why a task keeps dying): `log/handoffs/task_*.json` — `TaskHandoff`, one note per task, replayed as a prompt preamble on the next run. Off: `MCPTASK_TASK_HANDOFF=0`.
- **Raw stream**: `~/logs/mcptask_runner/<slug>.log`.
- **`/ci-runner`**: `~/.claude/logs/projects/<sha256-cwd>/ci-runner_<ts>.log`.

## Version Management
Version is **auto-incremented by the post-merge hook** (`bin/hooks/post-merge`) when `lib/` files change.
- **Do NOT run `ruby bin/increment_version.rb` manually** — the hook runs it after merge, so manual + hook = double increment.
- **EXCEPTION — direct/fast-forward push to `main`:** the hook only fires on an actual merge
- Hook installed via: `bin/install-hooks` (copies `bin/hooks/` into `.git/hooks/`)
