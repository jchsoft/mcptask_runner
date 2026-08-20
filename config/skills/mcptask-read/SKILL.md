---
name: mcptask-read
description: "Read mcptask.online pieces and return a COMPACT summary instead of raw MCP JSON. ALWAYS prefer this skill over calling the `mcp__mcptask-online__Get*`/`List*` read tools directly — raw piece payloads can be 2-10KB each and accumulate fast in the parent session. Use when the user says 'load task #N', 'load piece #N', 'story #N', 'next task', 'piece details', 'list pieces', 'download attachment', 'who am I', references an mcptask.online piece by ID, or any time you would otherwise read from the `mcptask-online` MCP server. Skill runs in a forked Haiku context — raw JSON never reaches the parent."
context: fork
model: haiku
allowed-tools: mcp__mcptask-online__GetPieceTool, mcp__mcptask-online__GetNextTaskTool, mcp__mcptask-online__GetCurrentUserTool, mcp__mcptask-online__ListPiecesTool, mcp__mcptask-online__GetPieceEffortsTool, mcp__mcptask-online__GetAttachmentTool, mcp__mcptask-online__GetProjectTool, mcp__mcptask-online__GetProjectTreeTool, mcp__mcptask-online__ListProjectsTool, mcp__mcptask-online__GetUsageGuideTool, ToolSearch, Bash, Read
---

# mcptask.online Read Skill

Fetch piece/user data from the `mcptask-online` MCP server and return a compact summary. The skill runs in a forked Haiku context so raw MCP JSON stays out of the parent.

## ⛔ HARD RULES — read first

1. **You ARE the forked Haiku context. You DO have MCP access.** Never return "I'm an agent without MCP access" — that is wrong. Either a read tool succeeds (possibly after retries), or you return the structured error block at the bottom.
2. **Read through the `mcp__mcptask-online__*` tools, never through `ReadMcpResourceTool`.** The built-in MCP *resource* reader is not available inside forked subagents — only MCP *tools* propagate. Reads that go through resources work in the parent and silently fail here.
3. **NEVER use Bash, curl, wget, Net::HTTP, or any HTTP client to fetch piece, user, or list data.** The mcptask.online HTTPS API path `/api/{account}/pieces/{id}` expects the internal `id` (NOT `relative_id`) — improvising HTTP returns the WRONG piece. (The one exception is the attachment *download* command you hand back to the parent — see "Attachment download".)
4. **Follow the steps in order. Do not skip Step 1.**

## Why this skill exists

The `mcptask-online` MCP server returns rich JSON: a single piece response can be 2-10KB, a list endpoint can be 50KB+. Each call accumulates in the parent context. The companion `mcptask-write` skill stays in the parent because IDs from write results are needed for next steps, but reads are pure data fetching — they belong in a fork that summarizes before returning.

If you find yourself about to call a `mcp__mcptask-online__Get*` tool in the parent, stop and call this skill instead.

## Input

The user message contains one of:

- piece ID (`load piece 10464`, `piece #10464`, `task #10464`, `story #10464`)
- next task request (`next task`, optionally with a project relative ID)
- attachment download (`download attachment <id> from piece <piece_relative_id>`) — you return the ready-to-run `curl` command; the **parent** runs it and Reads the file (see "Attachment download" below)
- user info (`who am I`)
- list of pieces (`list pieces`, with optional page/size)

## Args

Optional flag tokens after the piece reference:

- `with_attachments=false` — replace the full `### Attachments` block with a single comma-separated filename line. Use from triage / discovery prompts that only need extensions for content-type hints, not the IDs required for downloads. Default: `with_attachments=true` (full block).

Example: `load piece 10415 with_attachments=false`

## Account code

Default `account_code`: `jchsoft` unless the project's `CLAUDE.md` overrides it.

## Server label

MCP server key in `.mcp.json` is `mcptask-online`, reached over Streamable HTTP (`https://mcptask.online/mcp`). Tool names use prefix `mcp__mcptask-online__*`. Everything is a piece — there is no separate task/story endpoint.

> The server hides these read tools from legacy SSE clients (`config/initializers/fast_mcp.rb` → `StreamableOnlyToolsFilter` in projectoid_ii). If `.mcp.json` for this project still says `"type": "sse"`, the tools below will not exist — fix the transport, don't fall back to HTTP scraping.

## Tool map

| Tool | Args | Purpose |
|------|------|---------|
| `mcp__mcptask-online__GetPieceTool` | `account_code*`, `piece_relative_id*` | Piece details + attachments + subtasks |
| `mcp__mcptask-online__GetNextTaskTool` | `account_code*`, `project_relative_id` | Next most urgent task |
| `mcp__mcptask-online__ListPiecesTool` | `account_code*`, `page`, `size` | Paginated list of doable pieces |
| `mcp__mcptask-online__GetPieceEffortsTool` | `account_code*`, `piece_relative_id*` | Effort history (last 50) |
| `mcp__mcptask-online__GetAttachmentTool` | `account_code*`, `piece_relative_id*`, `attachment_relative_id*` | Attachment metadata + direct download URL |
| `mcp__mcptask-online__GetCurrentUserTool` | — | Current user info + working hours |
| `mcp__mcptask-online__GetProjectTool` | `account_code*`, project ref | Project details |
| `mcp__mcptask-online__GetProjectTreeTool` | `account_code*`, project ref | Project piece tree |
| `mcp__mcptask-online__ListProjectsTool` | `account_code*` | List of projects |
| `mcp__mcptask-online__GetUsageGuideTool` | — | Quick-start guide |

`piece_relative_id` (and `attachment_relative_id`) always name the account-scoped
relative id, never the internal `id` — the 2026-08-19 parameter rename put that
word in the argument name itself so the two can't be confused again.

> **Transitional note:** a server that predates the rename still expects the old
> names, `piece_id` / `attachment_id`, for the same value. If a call is rejected
> for an unrecognized argument, that's the sign — use the old name until the
> server updates, then this note (and the old names) can go.

## Step 1: Load the tool schema

```
ToolSearch(query: "select:mcp__mcptask-online__GetPieceTool", max_results: 1)
```

The `mcp__mcptask-online__*` tools are deferred — load the one you need (comma-separate several in one `select:`) before first use. Skipping this step is the #1 cause of this skill reporting a false "tool does not exist".

## Step 2: Fetch via the tool (with retry for connection race)

```
mcp__mcptask-online__GetPieceTool(account_code: "jchsoft", piece_relative_id: 10464)
```

**Connection race**: the server may still be in `pending` state at fork startup. The first call can fail with messages like "exists but is not enabled in this context" or "server not connected".

If the first call fails, do NOT give up and do NOT hallucinate. Retry up to 3 times with a short sleep between attempts:

```
Bash(command: "sleep 3", description: "Wait for mcptask-online to connect")
mcp__mcptask-online__GetPieceTool(account_code: "jchsoft", piece_relative_id: 10464)
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

When `with_attachments=false` is in args, replace the `### Attachments` block with a single line:
`Attachments ({count}): {filename1}, {filename2}, …` — emit `Attachments (0):` when there are none.

### Recent messages ({count})
(include up to 3 directly relevant to the current task, 1 line each)
```

### Next task

Same template as piece details, for the piece `GetNextTaskTool` returned.

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

Call `GetAttachmentTool` — it returns the attachment metadata plus a direct download URL, so you never hand-build the path. Slugify the filename for `-o` (strip spaces / non-ASCII; keep the extension), because attachment names often contain spaces and accented characters:

```
## Attachment — ready to download
- Piece: #{piece_relative_id} | Attachment id={attachment_id} relative_id={attachment_relative_id}
- Filename: {original_filename}
- Mime: {mime} | Size: {bytes}B
- Suggested local path: /tmp/piece_{piece_relative_id}_att_{attachment_id}.{ext}

The PARENT must run this, then Read the file and verify it exists (do NOT assume success):

    curl -fsS "{download_url from GetAttachmentTool}" -o /tmp/piece_{piece_relative_id}_att_{attachment_id}.{ext} && ls -l /tmp/piece_{piece_relative_id}_att_{attachment_id}.{ext}

If `curl` reports an HTTP error or the file is tiny/JSON, the download failed (wrong id or auth) — surface that, do not Read garbage as an image.
```

If you must construct the URL yourself, use `relative_id` (not the internal `id`) for the piece. Piece responses carry both: `id` is the internal DB row, `relative_id` is the URL-facing one. Using the wrong one returns a JSON error written into the file as if it were the image. The `-fsS` flags make `curl` fail loudly on HTTP errors instead of writing the error body into the file.

**Never** emit a "## Attachment downloaded" / "Path: …" success block — you did not download anything, so reporting a path the parent then fails to Read is the exact bug this skill avoids. Return only the command above.

## What to strip before returning

The parent only needs actionable signal. Drop:

- Full effort history (use `GetPieceEffortsTool` on demand if asked)
- Full message threads (only include 1-3 lines if relevant to the active task)
- Internal DB metadata (`created_at`, `updated_at`, soft-delete flags, audit fields) unless requested
- Nested duplicate fields (e.g. `project_id` + full `project` object — pick one)
- Locale YAML blobs, full code listings inside descriptions

Keep descriptions under 500 chars in the summary; the parent can ask for the full one explicitly if needed.

## Error handling

If the MCP call fails after 3 retries, return the error message exactly. Don't pad with hedges or apologies — the parent needs the raw signal to decide whether to retry, change tools, or surface to the user.

**Never** return fabricated explanations like "I'm an agent without MCP access", "you need to call this from the parent session", or "the skill is designed for fork context". You ARE the fork context. If the tool truly cannot reach the server, return:

```
## MCP error
- Tool: <tool name>
- Server: mcptask-online
- Args: <args you passed>
- Attempts: 3
- Last error: <exact error string from the tool>
```
