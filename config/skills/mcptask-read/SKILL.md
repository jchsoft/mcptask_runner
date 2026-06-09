---
name: mcptask-read
description: "Read mcptask.online pieces and return a COMPACT summary instead of raw MCP JSON. ALWAYS prefer this skill over calling ReadMcpResourceTool directly for any `mcptask://` URI — raw piece payloads can be 2-10KB each and accumulate fast in the parent session. Use when the user says 'load task #N', 'load piece #N', 'story #N', 'next task', 'piece details', 'list pieces', 'download attachment', 'who am I', references an mcptask.online piece by ID, or any time you would otherwise read from the `mcptask-online` MCP server. Skill runs in a forked Haiku context — raw JSON never reaches the parent."
context: fork
model: haiku
allowed-tools: ReadMcpResourceTool, Bash, ToolSearch, Read
---

# mcptask.online Read Skill

Fetch piece/user data from the `mcptask-online` MCP server and return a compact summary. The skill runs in a forked Haiku context so raw MCP JSON stays out of the parent.

## Why this skill exists

The `mcptask-online` MCP server returns rich JSON: a single piece response can be 2-10KB, a list endpoint can be 50KB+. Each call accumulates in the parent context. The companion `mcptask-write` skill stays in the parent because IDs from write results are needed for next steps, but reads are pure data fetching — they belong in a fork that summarizes before returning.

If you find yourself about to call `ReadMcpResourceTool` against an `mcptask://` URI in the parent, stop and call this skill instead.

## Input

The user message contains one of:

- piece ID (`load piece 10464`, `piece #10464`, `task #10464`, `story #10464`)
- next task request (`next task`, optionally with a project relative ID)
- attachment download (`download attachment <id> from piece <piece_id>`) — you return the ready-to-run `curl` command; the **parent** runs it and Reads the file (see "Attachment download" below)
- user info (`who am I`)
- list of pieces (`list pieces`, with optional page/size)

## Account code

Default `account_code`: `jchsoft` unless the project's `CLAUDE.md` overrides it.

## Server label

MCP server key in `.mcp.json` is `mcptask-online`. Tool names use prefix `mcp__mcptask-online__*`. Everything is a piece — the URI never uses `/tasks/` or `/stories/`.

## URI patterns

| URI | Purpose |
|-----|---------|
| `mcptask://pieces/{account_code}/{piece_id}` | Piece details + attachments + subtasks |
| `mcptask://pieces/{account_code}/@next?project_relative_id={id}` | Next most urgent task |
| `mcptask://pieces/{account_code}?page={page}&size={size}` | Paginated list of pieces |
| `mcptask://pieces/{account_code}/{piece_id}/efforts` | Effort history (read-only) |
| `mcptask://user` | Current user info + working hours |
| `mcptask://projects/{account_code}` | List of projects |
| `mcptask://how_to_use` | Quick-start guide |
| `mcptask://resource-templates` | All templated resources |

## Step 1: Load the tool schema if needed

```
ToolSearch(query: "select:ReadMcpResourceTool", max_results: 1)
```

`ReadMcpResourceTool` is a deferred tool — load it before first use.

## Step 2: Fetch via MCP (with retry for SSE race)

```
ReadMcpResourceTool(server: "mcptask-online", uri: "<URI from the table>")
```

**SSE race condition**: the `mcptask-online` MCP server uses SSE and may still be in `pending` state at fork startup. The first `ReadMcpResourceTool` call can fail with messages like "exists but is not enabled in this context" or "server not connected".

If the first call fails, do NOT give up and do NOT hallucinate. Retry up to 3 times with a short sleep between attempts:

```
Bash(command: "sleep 3", description: "Wait for mcptask-online SSE to connect")
ReadMcpResourceTool(server: "mcptask-online", uri: "<same URI>")
```

You ARE the forked Haiku context that owns the MCP connection. Do not return text like "I'm an agent without MCP access" — that is wrong. Either the tool eventually succeeds, or it fails after 3 retries and you return the literal error string from the last attempt (see Error handling below).

## Step 3: Return a compact summary

Extract only what the caller needs. Use the matching template below.

### Piece details

```
## Piece #{relative_id}: {name}
- **Type**: {task_type_code} | **State**: {task_state_code} | **Priority**: {priority}
- **Progress**: {progress}%
- **Project**: {project_name} (#{project_relative_id})
- **Duration best**: {duration_best_hours}h | **Worked**: {real_duration_hours}h
- **Internal id**: {id} | **Relative id**: {relative_id}

### Description
{first 500 chars; truncate longer with "…"}

### Subtasks ({count})
- #{rel_id} {name} [{state}] {progress}%
(max 10; append "… and N more" if longer)

### Attachments ({count})
- id={attachment_id} relative_id={attachment_relative_id} | {filename} ({size_bytes}B, {mime})
(list all — the parent needs both IDs to download)

### Recent messages ({count})
(include up to 3 directly relevant to the current task, 1 line each)
```

### Next task

Same template as piece details, for the piece the `@next` endpoint returned.

### Pieces list

```
## Pieces in {account_code} (page {page}, total {total})

- #{rel_id} {name} [{type}/{state}] priority={priority} progress={progress}%
(max 20 entries)
```

### User info

```
## User: {first_name} {last_name} (#{id})
- Email: {email}
- Accounts: {accounts}
- Hour goal: {hour_goal}h | Work start: {work_start}
- Worked out today: {worked_out}h | Remaining: {hour_goal - worked_out}h
```

### Attachment download

**You (the fork) do NOT download the file.** A fork's working directory and process are torn down when the skill returns; even though `/tmp` is shared, having the fork curl a file the parent then depends on is unreliable — and a fork that just emits a "downloaded" block without actually running curl leaves the parent Reading a path that does not exist. So: **return the command, let the parent run it.**

First fetch the piece via `mcptask://pieces/{account_code}/{piece_id}` so you have the real `relative_id`, the attachment's `relative_id`/`id`, the exact `filename`, and the `mime`. Then build a `curl` command the parent can paste verbatim. Save to a SAFE path — slugify the filename (strip spaces / non-ASCII; keep the extension), because attachment names often contain spaces and accented characters that break `-o`:

```
## Attachment — ready to download
- Piece: #{piece_relative_id} | Attachment id={attachment_id} relative_id={attachment_relative_id}
- Filename: {original_filename}
- Mime: {mime} | Size: {bytes}B
- Suggested local path: /tmp/piece_{piece_relative_id}_att_{attachment_id}.{ext}

The PARENT must run this, then Read the file and verify it exists (do NOT assume success):

    curl -fsS "https://mcptask.online/api/{account_code}/pieces/{piece_relative_id}/attachments/{attachment_id}/download" -o /tmp/piece_{piece_relative_id}_att_{attachment_id}.{ext} && ls -l /tmp/piece_{piece_relative_id}_att_{attachment_id}.{ext}

If `curl` reports an HTTP error or the file is tiny/JSON, the download failed (wrong id or auth) — surface that, do not Read garbage as an image.
```

Use `relative_id` (not the internal `id`) for the piece in download URLs. Piece responses carry both: `id` is the internal DB row, `relative_id` is the URL-facing one. Using the wrong one returns a JSON error written into the file as if it were the image. The `-fsS` flags make `curl` fail loudly on HTTP errors instead of writing the error body into the file.

**Never** emit a "## Attachment downloaded" / "Path: …" success block — you did not download anything, so reporting a path the parent then fails to Read is the exact bug this skill avoids. Return only the command above.

## What to strip before returning

The parent only needs actionable signal. Drop:

- Full effort history (use the `/efforts` URI on demand if asked)
- Full message threads (only include 1-3 lines if relevant to the active task)
- Internal DB metadata (`created_at`, `updated_at`, soft-delete flags, audit fields) unless requested
- Nested duplicate fields (e.g. `project_id` + full `project` object — pick one)
- Locale YAML blobs, full code listings inside descriptions

Keep descriptions under 500 chars in the summary; the parent can ask for the full one explicitly if needed.

## Error handling

If the MCP call fails after 3 retries, return the error message exactly. Don't pad with hedges or apologies — the parent needs the raw signal to decide whether to retry, change URIs, or surface to the user.

**Never** return fabricated explanations like "I'm an agent without MCP access", "you need to call this from the parent session", or "the skill is designed for fork context". You ARE the fork context. If `ReadMcpResourceTool` truly cannot reach the server, return:

```
## MCP error
- Tool: ReadMcpResourceTool
- Server: mcptask-online
- URI: <attempted URI>
- Attempts: 3
- Last error: <exact error string from the tool>
```
