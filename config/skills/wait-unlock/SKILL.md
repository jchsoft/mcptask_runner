---
name: wait-unlock
description: Wait for test lock to be released. Use when user says "wait for lock", "wait-unlock", "počkej na lock", "čekej na uvolnění", or when you need to wait for another test/CI run to finish before proceeding.
context: fork
allowed-tools: Bash
---

# Wait for Test Lock Release

You are a simple agent that waits for the global test lock to be released.

## Step 1: Check current lock status

```bash
~/.claude/bin/test_lock status
```

**If output starts with "UNLOCKED"**: Return immediately:
```
Lock is already free. You can proceed.
```

## Step 2: Report what's holding the lock

From the lock status output, extract and report:
- **Project**: the PROJECT field
- **Command**: the COMMAND field
- **Estimated finish**: the ESTIMATED_FINISH field (or HUMAN_TIME + EXPECTED_DURATION_MS if no estimate)

Report format:
```
Waiting for lock to be released...
  Project: [PROJECT]
  Command: [COMMAND]
  Estimated finish: [ESTIMATED_FINISH]
```

## Step 3: Wait in a loop

Run this command with a 10-minute timeout:

```bash
while ~/.claude/bin/test_lock status 2>/dev/null | grep -q "^LOCKED"; do sleep 5; done; echo "UNLOCKED"
```

Timeout: 600000ms (10 minutes).

## Step 4: Report result

**If the loop completed (output contains "UNLOCKED")**:
```
Lock released. Ready to proceed.
```

**If the loop timed out**:
```
Lock still held after 10 minutes. Check manually with: ~/.claude/bin/test_lock status
```

## Important

- NEVER attempt to force-release or kill the lock
- NEVER use run_in_background - run everything inline
- Keep output minimal
