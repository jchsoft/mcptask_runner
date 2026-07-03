---
name: test-start
description: Internal helper for /test-runner. Acquires the global test lock and launches the given test command detached, or reports that another agent is running. Not meant for direct user invocation — use /test-runner instead.
context: fork
model: haiku
allowed-tools: Bash
---

# test-start

Internal helper invoked by `/test-runner`. Runs a single shell script and returns its output verbatim.

## Args

`args` is whitespace-separated: `<expected_sec> <command...>`

- `expected_sec` — integer; orchestrator uses this to size /test-wait cycles.
- `command` — full test command, e.g. `bin/rails test test/models/foo_test.rb`.

## Task

1. Run via Bash: `~/.claude/bin/test_start <args>` (pass args through unchanged).
2. Return stdout verbatim. No summary, no prose.

## Output contract

The script always exits 0 with one of three blocks. Return exactly what it prints:

**Lock acquired, run launched:**
```
TEST_STARTED
TEST_LOG=<absolute path to log file>
EXPECTED_SEC=<integer>
NEXT=Skill(test-wait, args="self <TEST_LOG>") — ...
```

The test run is now detached and running. This block IS the successful result — the
`Skill "test-start" completed (forked execution)` banner the harness prints after it is
just a wrapper notice, NOT a sign the skill returned nothing. The `NEXT=` line tells the
orchestrator exactly which call to make next.

**Another agent holds the lock:**
```
TEST_LOCKED
OTHER_LOG=<absolute path or "unknown">
OTHER_PROJECT=<absolute path>
OTHER_REMAINING=<string like "12m 34s" or "overdue by Xs" or "unknown">
```

**Error:**
```
TEST_ERROR
REASON=<short identifier>
<diagnostic tail>
```

Do not interpret. The orchestrator (`/test-runner`) parses these.
