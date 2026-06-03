## Project-specific lookup hints

Generic exploration order (Memory → `/discover` → CodeGraph → LSP → Read → Grep) and skill-first MCP rules live in `~/.claude/CLAUDE.md`. mcptask-runner gotchas:

- **Concerns / namespace modules** (`InstructionBuilding`, `RetryHandling`, `StreamProcessing`, `UrgentBugPin`, etc.) — CodeGraph won't index them. Use `/discover` (handles the Ruby `module` caveat) or LSP `documentSymbol` on the concern file.

## LLM Memory Notes MCP Usage
- Memory identifier: `wv-runner` (architecture, patterns, commands, testing info)

## mcptask.online
- Project name is: "McpTask rails runner"
- project_relative_id=69
- account_code: `jchsoft`

## CI & Quality Checks
- **Full CI**: `ruby bin/ci` — all checks (tests, RuboCop, Reek, Flay)
- **Tests only**: `ruby test_runner.rb`
- **Individual tests**: `ruby -I lib -I test test/services/<test_file>.rb`
- **All checks must pass before commit**

## Version Management
Version is **auto-incremented by the post-merge hook** (`bin/hooks/post-merge`) when `lib/` files change.
- **Do NOT run `ruby bin/increment_version.rb` manually** — the hook runs it after merge, so manual + hook = double increment.
- Version file: `lib/mcptask_runner/version.rb`
- Pattern: 0.1.0 → 0.1.1 → ... → 0.1.9 → 0.2.0 → etc
- Hook installed via: `bin/install-hooks` (copies `bin/hooks/` into `.git/hooks/`)
