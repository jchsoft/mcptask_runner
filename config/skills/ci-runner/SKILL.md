---
name: ci-runner
description: Run local CI (bin/ci) and report what needs fixing. Use when user says "bin/ci", "run ci", "lokální CI", "spusť CI", "pusť CI", "ci check", or wants to run the full CI pipeline locally.
allowed-tools: Skill, Read
---

# CI Runner

Orchestrates `/ci-start` + `/ci-wait` to run local CI safely on a machine shared with other Claude agents. Preserves the global CI lock (`/tmp/claude_test_run.lock`) so two agents never run system tests at the same time.

You (the main agent) drive this state machine directly. Do NOT poll logs yourself. Do NOT use Monitor. Do NOT read `latest_ci-runner.log`. Your only tools here are the two sub-skills below.

## State machine

```
outer_iterations = 0
while outer_iterations < 10:
  outer_iterations += 1

  result = Skill(ci-start)
  parse result

  if result starts with "CI_LOCKED":
    # Another agent holds the lock. Wait for THEIR CI to finish,
    # then retry ci-start to acquire for ourselves.
    inner = 0
    while inner < 8:                       # 8 × 9min = 72min cap
      inner += 1
      w = Skill(ci-wait, args="other <OTHER_LOG>")
      if w starts with "NOT_FINISHED":
        continue
      if w starts with "FINISHED_OTHER":
        break                              # other agent done, go retry ci-start
      if w starts with "FAILED_EXTERNAL":
        report w to user, STOP
    else:
      report "Other agent's CI did not finish after 72 min. Lock may be stuck. Run ~/.claude/bin/test_lock status to inspect."
      STOP
    continue  # back to outer_iterations loop, retry ci-start

  if result starts with "CI_STARTED":
    # We launched. Wait for our own CI.
    max_waits = max(6, min(8, ceil(EXPECTED_SEC / 540) + 2))  # floor 6 → ≥54min; ROR system-test suites run ~30min+
    waits = 0
    while waits < max_waits:
      waits += 1
      w = Skill(ci-wait, args="self <CI_LOG>")
      if w starts with "NOT_FINISHED":
        # A NOT_FINISHED with an empty LAST= now carries a DIAG=/PROC= line.
        # PROC=dead means CI crashed producing no output — don't spin the full
        # cap; report the diagnostic and STOP. PROC=alive means it's just
        # silent (long asset/setup step) — keep waiting.
        if w contains "PROC=dead":
          report "CI process died with no output. Log at CI_LOG. Diagnostic: <the DIAG=/PROC= lines>. Run ~/.claude/bin/test_lock kill to clean up." , STOP
        continue
      if w starts with "FINISHED_SELF":
        parse the ---BEGIN_LOG_TAIL---...---END_LOG_TAIL--- block and EXIT_CODE
        produce the structured report (see "Report format" below)
        save duration to tmp/test_durations.json (see "After CI" below)
        STOP — DONE
      if w starts with "FAILED_EXTERNAL":
        report w, STOP
    report "Our CI did not finish after max_waits cycles. Log at CI_LOG. Run ~/.claude/bin/test_lock kill to clean up."
    STOP

  if result starts with "CI_ERROR":
    report the error and STOP

report "ci-start did not succeed after 10 outer iterations" and STOP
```

The 10-outer-iterations cap prevents infinite loops if the lock is pathologically stuck. In practice outer loop runs once (our CI) or twice (wait for other, then ours).

## Report format (on FINISHED_SELF)

`EXIT_CODE` is CI's exit code (0 = all green). On `EXIT_CODE=0`, `/ci-wait` emits `ALL_OK` with no log block — parent context stays clean. On non-zero, a `---BEGIN_LOG_TAIL---...---END_LOG_TAIL---` block follows containing a filtered tail (signal lines only; asset writes, deprecation warnings, dotted progress collapsed).

### On EXIT_CODE=0

`/ci-wait` emits an `ALL_OK` marker followed by ≤20 summary lines (step ✅ markers, Minitest "Runs/Assertions/Finished in" lines, total CI time). Use these to fill the report — do NOT ask for the full log tail.

```
✅ CI passed — all steps green
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Steps: N passed | Time: Xm Ys
```

### On EXIT_CODE != 0

Parse the log tail for step markers (lines beginning with `✅` / `❌` in bin/ci output, or step labels like `Tests: Rails`, `Tests: System`, `Style: Ruby`, etc.). For failed steps, extract:

- **RuboCop**: offenses with `file:line` and cop name
- **Rails/system tests**: failure messages with `file:line` and error excerpt
- **Security audit**: vulnerability CVE + package name
- **Asset issues**: compilation errors

Emit:

```
❌ CI failed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[✅ or ❌] <step name>
   → <error detail, if failed>
...

🔧 To fix:
1. <concrete action>
2. <concrete action>
```

Be specific: file paths, line numbers, the actual failing assertion. Group similar errors.

## After CI (FINISHED_SELF only)

Save the run's duration for next time's adaptive timeout. The log footer contains `Started: …` and `Finished: …` timestamps; compute the difference in milliseconds.

```bash
mkdir -p tmp && ruby -e '
require "json"
require "time"
path = "tmp/test_durations.json"
data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
# Replace with actual computed values:
data["ci"] = { "last_duration_ms" => <MS>, "last_run" => "<YYYY-MM-DD>" }
File.write(path, JSON.pretty_generate(data))
'
```

Skip this if `FINISHED_SELF` came with `EXIT_CODE` that suggests the run was killed abnormally (e.g. 137 SIGKILL).

## Lock cleanup

You do NOT need to call `test_lock release`. `run_with_log` auto-releases the lock when `bin/ci` exits, via its internal `test_lock release_if_owner ci-runner` on-exit hook.

Only call `~/.claude/bin/test_lock kill` if the waiter loop exhausted its iteration cap without completion (runaway CI). Never bypass a valid lock held by another agent.

## Important

- **Never** poll the log file directly. Only the `/ci-wait` sub-skill does that, via `~/.claude/bin/ci_wait`.
- **Never** invoke Monitor for CI waits. `/ci-wait` already handles polling internally.
- **Never** read `~/.claude/logs/latest_ci-runner.log` — logs are now per-project at `~/.claude/logs/projects/<slug>/`. `/ci-start` returns the correct path; use it.
- **Never construct or guess the log path.** Always pass `CI_LOG=...` (from `/ci-start` output) or `OTHER_LOG=...` verbatim into `/ci-wait`. Project slugs are sha256 hashes, not human-readable names like `projectoid_ii`. Fabricated paths cause 9-minute NOT_FINISHED polling loops that spin until the iteration cap.
- If `OTHER_LOG=unknown`, do NOT call `/ci-wait` with `"unknown"` — instead fall through to the outer retry loop and call `/ci-start` again after a brief delay; the other agent's log may have appeared by then.
- If `/ci-wait` returns `FAILED_EXTERNAL` with `REASON=log_missing` or `REASON=invalid_log_path`, STOP — do not retry. The path is wrong; user intervention needed.
- If you see `CI_LOCKED`, never try to kill or release the other agent's lock. Wait it out via `/ci-wait mode=other`.
