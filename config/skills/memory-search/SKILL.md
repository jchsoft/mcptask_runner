---
name: memory-search
description: "Search LLM Memory Notes and return compact, filtered summary. Use when CLAUDE.md instructs to search memory notes before coding, or when user says 'search memory', 'hledej v paměti', 'co víme o X'."
context: fork
allowed-tools: Bash, ToolSearch, mcp__llmmn-production__RateNoteTool
---

# Memory Search Skill

Search LLM Memory Notes and return a compact, relevant summary.
This skill exists to prevent verbose memory note results from bloating the main session context.

## ⛔ HARD RULES — read first

1. **You ARE the forked context.** Never return "I'm an agent without MCP access" or delegate the search back to the parent — that defeats the whole point of the fork. Either the search succeeds, or you return the error block at the bottom.
2. **Search via the REST API with `Bash`/`curl`, not via `ReadMcpResourceTool`.** The llm-memory.com MCP server exposes search only as an MCP *resource*, and the built-in resource reader is **not available inside forked subagents** — only MCP *tools* propagate. `ToolSearch(query: "select:ReadMcpResourceTool")` returns "No matching deferred tools found" here. Don't waste turns on it.

## Input

The user message contains:
- **query**: what to search for (task topic, architecture concept, pattern name)
- **memory_identifier**: which memory to search (e.g., `projektoid_ii`, `wv-runner`)

If memory_identifier is not specified, check the project's CLAUDE.md for the identifier.

## Step 1: Search Memory Notes

Run up to 2 searches (task-specific + architecture if needed):

```
curl -fsS -X POST https://llm-memory.com/api/v1/search \
  -H "Authorization: Bearer $LLMMN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"memory_identifier\":\"MEMORY_ID\",\"query\":\"QUERY\",\"limit\":3}" \
  --max-time 25
```

`$LLMMN_TOKEN` is already in the environment — do not print it, do not hardcode it.

**Always use `limit=3`** (not 5) to reduce noise. The query goes in the JSON body, so no URL encoding is needed.

Response shape: `{"results":[{"title":…,"content":…,"score":…}, …]}`. Higher `score` = closer match.

## Step 2: Filter and Summarize

For each returned note, evaluate relevance to the query:
- **Relevant** (high): directly relates to the task/topic being searched
- **Marginally relevant** (medium): same area of codebase but different feature
- **Irrelevant**: completely unrelated → discard from output

### Rating (only when note IDs are available)

The REST search response does **not** include note IDs, so rating is not possible on that path — skip it rather than guessing an ID. `mcp__llmmn-production__RateNoteTool(identifier:, note_id:, rating:)` stays available for when a caller hands you a concrete note ID.

> Follow-up that would restore rating: llm_memory_notes exposes search only as `NotesSearchResource`. Wrapping it in a `SearchNotesTool` (the pattern projectoid_ii uses in `app/tools/get_piece_tool.rb` via `read_resource`) would make search reachable as an MCP tool inside forks *and* return note IDs.

## Step 3: Return Compact Output

Return ONLY this structured format:

```
## Memory Search: "QUERY" (MEMORY_ID)

### [Note Title] (relevance: high/medium)
- **Pattern**: [key pattern or approach used, 1-2 lines]
- **Files**: [key file paths, max 5]
- **Gotchas**: [important pitfalls or decisions, 1-2 lines]

### [Next Note Title] (relevance: high/medium)
...

### No relevant notes found
(if nothing matched)
```

## Rules

- **MAX 150 words per note summary** — strip PR numbers, test counts, full locale structures, verbose implementation details
- **DISCARD irrelevant notes entirely** — do not include them in output
- **Focus on PATTERNS and DECISIONS** — what approach was used, what file structure to follow, what pitfalls to avoid
- **Include file paths** — these are the most actionable piece of information
- **Never include**: full code blocks, test output, PR descriptions, CI results, locale YAML structures

## Error handling

If `curl` fails (non-zero exit, HTTP error, or empty `results`), return the exact error — do not fabricate notes:

```
## Memory search error
- Endpoint: POST https://llm-memory.com/api/v1/search
- Memory: MEMORY_ID
- Query: QUERY
- Error: <exact curl/HTTP error or response body>
```
