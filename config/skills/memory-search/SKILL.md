---
name: memory-search
description: "Search LLM Memory Notes and return compact, filtered summary. Use when CLAUDE.md instructs to search memory notes before coding, or when user says 'search memory', 'hledej v paměti', 'co víme o X'."
context: fork
model: haiku
allowed-tools: ReadMcpResourceTool, ToolSearch, mcp__llmmn-production__RateNoteTool
---

# Memory Search Skill

Search LLM Memory Notes and return a compact, relevant summary.
This skill exists to prevent verbose memory note results from bloating the main session context.

## Input

The user message contains:
- **query**: what to search for (task topic, architecture concept, pattern name)
- **memory_identifier**: which memory to search (e.g., `projektoid_ii`, `wv-runner`)

If memory_identifier is not specified, check the project's CLAUDE.md for the identifier.

## Step 1: Search Memory Notes

Run up to 2 searches (task-specific + architecture if needed):

```
ReadMcpResourceTool(
  server: "llmmn-production",
  uri: "llm-memory-notes://search/notes?query=QUERY_URL_ENCODED&memory_identifier=MEMORY_ID&limit=3"
)
```

**IMPORTANT: Always use `limit=3`** (not 5) to reduce noise.

## Step 2: Filter, Rate, and Summarize

For each returned note, evaluate relevance to the query:
- **Relevant** (high): directly relates to the task/topic being searched → **upvote** (+1)
- **Marginally relevant** (medium): same area of codebase but different feature → **downvote** (-1)
- **Irrelevant** (none): completely unrelated → **downvote** (-1), discard from output

### Rate every note

Rate ALL returned notes based on their relevance evaluation:

```
mcp__llmmn-production__RateNoteTool(
  identifier: "MEMORY_ID",
  note_id: <note id from search results>,
  rating: +1  # for relevant, -1 for marginally relevant or irrelevant
)
```

This trains the search to surface better results over time. A note needs ~10 downvotes to be suppressed, so consistent rating matters.

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
- URL-encode all query parameters (spaces → `%20`)
