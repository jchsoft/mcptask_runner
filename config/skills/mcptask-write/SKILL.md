---
name: mcptask-write
description: "Write to mcptask.online — create pieces (tasks/stories/recurents), log work progress, attach files, post messages. ALWAYS prefer this skill over calling `mcp__mcptask-online__*` write tools directly, so the workflow rules (English-only content, progressive logging cadence, store-note-after-completion) are followed. Use when the user says 'create mcptask task', 'create piece', 'create story', 'create subtask', 'log progress', 'log work', 'add attachment to piece', 'add comment to piece', 'add message to piece', or finishes a task that needs progress recorded. Runs in the parent context because the returned IDs (new piece IDs, effort IDs) are needed for subsequent steps."
---

# mcptask.online Write Skill

Write operations against the `mcptask-online` MCP server. Lives in the parent context because the returned IDs (new piece IDs, effort IDs) are needed for next steps.

For reads — piece details, next task, list, attachment download, user info — use the `mcptask-read` skill instead. That one forks to Haiku and returns a compact summary so the raw JSON never bloats the parent.

## Account code

Default `account_code`: `jchsoft` unless the project's `CLAUDE.md` overrides it.

## Server label

MCP server key in `.mcp.json` is `mcptask-online`. Tool prefix: `mcp__mcptask-online__*`. Everything is a piece — schema does not distinguish tasks vs. stories at the URI level.

## Write tools

| Tool | Purpose |
|------|---------|
| `mcp__mcptask-online__CreatePieceTool` | Create a Task / Story / Recurent / Bug |
| `mcp__mcptask-online__LogWorkProgressTool` | Log progressive work effort |
| `mcp__mcptask-online__AddAttachmentTool` | Attach a file to a piece |
| `mcp__mcptask-online__AddMessageTool` | Add a comment / message to a piece |
| `mcp__llmmn-production__AddNoteTool` | Store an implementation note after the task is done |

## CreatePieceTool

`name` and `description` must be in English regardless of conversation language, because mcptask.online is read by mixed-language collaborators and the backend search/index is tuned for English.

Required: `account_code`, `name`, `task_type_code` (`task`, `story`, `recurent`, `bug`), `project_relative_id`, `scrum_point_code`.
Optional: `description`, `priority`, `parent_id` (for subtasks), `duration_best_hours`.

`scrum_point_code` (difficulty) is **required** — omitting it fails validation: "Trvání optimisticky/pesimisticky není v seznamu povolených hodnot". Pick by type:

- Task / Recurent / Bug: `!` (0), `S` (3), `M` (5), `L` (8), `XL` (13), `XXL` (40), `XXXL` (100)
- Story: `m!` (0), `mS` (42), `mM` (70), `mL` (112), `mXL` (182), `mXXL` (560), `mXXXL` (1400)

## LogWorkProgressTool — progressive logging

Log multiple times during a task, not only at the end. Stakeholders watching the piece see live progress instead of a wall of silence followed by a 100% commit.

| Progress | When to log |
|----------|-------------|
| 25% | After the analysis / planning phase is done |
| 50% | After the core functionality is implemented |
| 75% | After tests and basic verification pass |
| 90% | After final completion (leave room for follow-ups) |
| 100% | Only when truly done, including the commit |

Required arguments: `account_code`, `task_id`, `description`, `progress_percent`, `duration_minutes`.

Don't log work to Stories directly — Stories are containers. Log to the subtask piece that actually had the work done on it.

A practical rule: every checked todo item is a small chunk of effort. Translate that into a `LogWorkProgressTool` call with the appropriate percentage. The cost is trivial and the visibility win is large.

## AddAttachmentTool

Required: `account_code`, `piece_id` (use `relative_id`), `file_path` (absolute path on local disk), `filename`.

Typical sources: system-test screenshots, `/run` skill output, exported reports.

## AddMessageTool

Required: `account_code`, `piece_id` (use `relative_id`), `body`.

For status updates and comments on a piece thread.

## After task completion

1. Refactor for Ruby/Rails philosophy — see `~/.claude/rules/ruby-rails.md`. The point is to keep the codebase in its conventional shape, not to chase style after the fact.
2. Ensure all tests pass before you log 100%.
3. Store an implementation note with `mcp__llmmn-production__AddNoteTool`. Title pattern: `Feature: …`, `Bugfix: …`, `Refactor: …`. Content: key file paths, the pattern/decision, the gotcha that took time to find. Skip full code blocks, test output, PR descriptions, locale YAML — those bloat the note and don't help future-you. The note exists so the next session can find the lesson in 200 words, not re-read your PR.
4. Final `LogWorkProgressTool` call with `progress_percent: 100` after the commit.

## Use `relative_id`, not `id`

Every user-facing reference (URLs, attachment downloads, write-tool `piece_id` arguments) uses `relative_id`. The internal `id` is for the DB only; passing it where `relative_id` is expected returns errors that look like success (e.g., a JSON error body saved into a `.png` file).
