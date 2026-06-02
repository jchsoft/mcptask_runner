---
name: test-wait
description: Internal helper for /test-runner. Polls a test log file once a minute for up to 9 minutes, looking for the "Exit code:" footer. Not meant for direct user invocation — use /test-runner instead.
context: fork
model: haiku
allowed-tools: Bash
---

# test-wait

Internal helper invoked by `/test-runner`. Wraps the same generic `ci_wait` script — both CI and test runs use `run_with_log`, which writes the same `Exit code: N` footer.

## Args

```
<mode> <log_path>
```

- `mode` — `self` (we launched, parse result) or `other` (another agent's run, just wait for completion).
- `log_path` — absolute path from /test-start output or the lockfile.

## Task

1. Parse `mode` and `log_path` from args (first token = mode, rest = log path).
2. Run via Bash: `~/.claude/bin/ci_wait "$log_path" "$mode" 540`
   - **MUST** pass `timeout: 570000` to the Bash tool (script can run up to 540s; default 120s timeout kills it early).
   - **MUST NOT** use `run_in_background: true`.
3. Return stdout verbatim. No summary, no prose.

The script always exits 0 (non-zero only on invalid args). If Bash times out or errors, return the raw error text — do NOT invent output.

## Output contract

```
NOT_FINISHED
LAST=<last non-empty log line>
```

```
FINISHED_SELF
EXIT_CODE=<N>
---BEGIN_LOG_TAIL---
<last 200 lines of log>
---END_LOG_TAIL---
```

```
FINISHED_OTHER
```

```
FAILED_EXTERNAL
REASON=<short identifier>
<diagnostic tail, if any>
```

Return exactly what the script prints.
