---
name: test-runner
description: Run Rails tests with intelligent timeout and structured output. Use when user says "rails test", "run tests", "spusť testy", "pusť testy", "otestuj", "test:system", "test:all", or wants to execute any tests.
allowed-tools: Skill, Read, Bash
---

# Test Runner

Orchestrates `/test-start` + `/test-wait` to run Rails tests safely on a machine shared with other Claude agents. Preserves the global lock (`/tmp/claude_test_run.lock`) so two agents never run system tests at the same time.

You (the main agent) drive the state machine directly. Do NOT poll logs yourself. Do NOT use Monitor. Do NOT read `latest_test-runner.log`. Your only tools are the two sub-skills below plus a tiny bit of Bash for reading `tmp/test_durations.json` and saving the new duration.

## Step 1: Pick command + test type

**Default**: if user did not specify, run `bin/rails test` (all unit tests). Never ask for clarification.

| User intent              | Command                                  | Type key      | Adaptive? |
|--------------------------|------------------------------------------|---------------|-----------|
| all unit tests           | `bin/rails test`                         | `unit`        | yes       |
| system tests             | `bin/rails test:system`                  | `system`      | yes       |
| all tests                | `bin/rails test:all`                     | `all`         | yes       |
| specific file            | `bin/rails test path/to/file.rb`         | `file`        | no        |
| system test file         | `bin/rails test test/system/...`         | `system_file` | no        |
| specific line            | `bin/rails test file.rb:LINE`            | `line`        | no        |

## Step 2: Compute expected_sec

For full-suite types (`unit`/`system`/`all`): read `tmp/test_durations.json` once via `cat tmp/test_durations.json 2>/dev/null || true`.

If JSON has `data[TYPE]`:
- `expected_sec = max(last_duration_ms, max_duration_ms) * 1.5 / 1000` (seconds)
- Clamp: `unit` min 120s; `system`/`all` min 300s; max 2400s for all.

If no entry, defaults: `unit`=240, `system`=480, `all`=600.

For non-adaptive types: fixed defaults `file`=120, `system_file`=180, `line`=60.

## Step 3: Drive the state machine

```
outer_iterations = 0
while outer_iterations < 10:
  outer_iterations += 1

  result = Skill(test-start, args="<expected_sec> <command>")
  parse result

  if result starts with "TEST_LOCKED":
    # Another agent holds lock. Wait for THEIR run, then retry test-start.
    inner = 0
    while inner < 8:                       # 8 × 9min = 72min cap
      inner += 1
      w = Skill(test-wait, args="other <OTHER_LOG>")
      if w starts with "NOT_FINISHED":
        continue
      if w starts with "FINISHED_OTHER":
        break                              # other agent done, retry test-start
      if w starts with "FAILED_EXTERNAL":
        report w to user, STOP
    else:
      report "Other agent's run did not finish after 72 min. Run ~/.claude/bin/test_lock status to inspect."
      STOP
    continue                               # back to outer loop, retry test-start

  if result starts with "TEST_STARTED":
    max_waits = max(3, min(8, ceil(EXPECTED_SEC / 540) + 2))
    waits = 0
    while waits < max_waits:
      waits += 1
      w = Skill(test-wait, args="self <TEST_LOG>")
      if w starts with "NOT_FINISHED":
        continue
      if w starts with "FINISHED_SELF":
        parse the ---BEGIN_LOG_TAIL---...---END_LOG_TAIL--- block and EXIT_CODE
        produce structured report (see "Report format")
        save duration if eligible (see "After run")
        STOP — DONE
      if w starts with "FAILED_EXTERNAL":
        report w, STOP
    report "Tests did not finish after max_waits cycles. Log at TEST_LOG. Run ~/.claude/bin/test_lock kill to clean up."
    STOP

  if result starts with "TEST_ERROR":
    report the error and STOP

report "test-start did not succeed after 10 outer iterations" and STOP
```

The 10-outer-iterations cap prevents infinite loops if the lock is pathologically stuck. Outer loop normally runs once (our run) or twice (wait for other, then ours).

## Report format (FINISHED_SELF)

The `---BEGIN_LOG_TAIL---...---END_LOG_TAIL---` block is the last 200 lines of the test log. `EXIT_CODE` is the test process's exit code.

### EXIT_CODE=0
```
✅ Tests passed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Runs: X | Assertions: Y | Time: Z.Zs
```

Pull `Runs:` / `Assertions:` / `Finished in X.XXs` from the log tail (Minitest summary).

### EXIT_CODE != 0

Parse failed test entries from the log tail. For each failure extract: `path/to/file.rb:LINE`, test name, error message.

```
❌ Tests failed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Runs: X | Failures: Y | Errors: Z

Failed tests:
1. path/to/file.rb:LINE - test_name
   Error: <message>
2. ...
```

Be specific: file paths, line numbers, the actual failing assertion. Group similar errors. For compilation/syntax errors, surface them up front instead of the failure list.

### Abnormal exit (137 SIGKILL, etc.)

Report the exit code + log path. Skip the duration save.

## After run (save duration)

Save ONLY when ALL of:
- `EXIT_CODE` is 0 or a normal test failure (NOT 137/143/etc.).
- Test type is full suite: `unit`, `system`, or `all`. **Never** for `file`/`system_file`/`line`.

Extract `Finished in X.XXs` from the log tail. `duration_ms = round(X.XX * 1000)`.

```bash
mkdir -p tmp && ruby -e "
require 'json'
path = 'tmp/test_durations.json'
data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
entry = data['REPLACE_TYPE'] || {}
old_max = entry['max_duration_ms'] || 0
data['REPLACE_TYPE'] = { 'last_duration_ms' => REPLACE_MS, 'max_duration_ms' => [old_max, REPLACE_MS].max, 'last_run' => 'REPLACE_DATE' }
File.write(path, JSON.pretty_generate(data))
"
```

Substitute: `REPLACE_TYPE` (`unit`/`system`/`all`), `REPLACE_MS` (integer ms), `REPLACE_DATE` (`YYYY-MM-DD`).

## Lock cleanup

`run_with_log` auto-releases the lock when the test process exits, via its on-exit hook (`test_lock release_if_owner test-runner`). You do NOT need to call `test_lock release`.

Only call `~/.claude/bin/test_lock kill` if the waiter loop exhausted its iteration cap (runaway run). Never bypass a lock held by another agent.

## Important

- **Never** poll the log file directly. Only `/test-wait` does that, via `~/.claude/bin/ci_wait`.
- **Never** invoke Monitor for waits.
- **Never** read `latest_test-runner.log` — `/test-start` returns the correct path; use it.
- If you see `TEST_LOCKED`, never kill the other agent's lock. Wait it out via `/test-wait other`.
