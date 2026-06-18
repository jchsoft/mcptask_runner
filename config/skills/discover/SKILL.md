---
name: discover
description: "Find a symbol, function, class, method, route, or any code location using the precise tool for the job — CodeGraph first, LSP next, Grep only as last resort. ALWAYS prefer this skill over running Grep/Glob/Read directly when exploring code. It picks the cheapest tool, falls back when one tool draws a blank, and returns compact `file:line` results so the parent never sees raw greps or whole-file dumps. Use when the user says 'find X', 'where is X', 'where is X defined', 'who calls X', 'who uses X', 'show me X', 'what calls Y', 'what does Y call', 'what's the impact of changing Z', 'find similar implementations', or whenever you're about to start an exploration. For concept / pattern / lesson-learned queries (architecture, decisions, past bugs) use `/memory-search` instead — this skill is for code locations."
context: fork
model: haiku
allowed-tools: mcp__codegraph__codegraph_search, mcp__codegraph__codegraph_context, mcp__codegraph__codegraph_callers, mcp__codegraph__codegraph_callees, mcp__codegraph__codegraph_impact, mcp__codegraph__codegraph_node, mcp__codegraph__codegraph_files, mcp__codegraph__codegraph_status, mcp__railsMcpServer__project_info, mcp__railsMcpServer__get_routes, mcp__railsMcpServer__get_schema, mcp__railsMcpServer__analize_models, mcp__railsMcpServer__get_models, mcp__railsMcpServer__analyze_controller_views, mcp__railsMcpServer__analyze_environment_config, mcp__railsMcpServer__switch_project, LSP, Grep, Glob, Read, ToolSearch
---

# Code Discovery Skill

Find code locations using the cheapest tool first. Runs in a forked Haiku context so the parent only sees compact `file:line` results, not raw tool output.

## Why this skill exists

Direct Grep/Glob/Read sequences are the most common context-bloat anti-pattern: `Glob lib/**/*.rb` (45 file paths) → `wc -l` → `Read` of a 400-line file just to find one method definition is ~10KB of parent context for a single lookup. CodeGraph or LSP can return the same `file:line` in a few hundred bytes. The user's CLAUDE.md mandates the exploration order, but mandating it isn't enough — this skill encodes it so the parent stays lean automatically.

## Input

The parent's invocation message contains a discovery query, one of:

- **Exact symbol**: `find ContextOverflowError`, `where is build_command`, `show me TodayAutoSquash`
- **Reference / call graph**: `who calls handle_context_overflow`, `what does build_instructions call`, `impact of changing effective_model_name`
- **Concept matching a name pattern**: `find anything about quota`, `methods named *retry*`
- **File-scoped overview**: `what's in claude_code_base.rb`
- **Open-ended exploration**: `find code that handles MCP tool errors`

If the query is about **concepts, patterns, lessons, or past decisions** (not code locations), return a single line redirecting the parent to `/memory-search` — that's the right tool, not this one.

## Routing table

**On a Rails project, rails-mcp-server is the first thing to reach for.** Its tools answer from the live app (routes, models, schema, views), so for any Rails-domain query they beat CodeGraph/LSP/Grep — try them first, fall through only when the server is absent or errors (see the rails-mcp-server section). CodeGraph stays first for plain symbol / call-graph lookups that aren't Rails-domain.

Pick the first row that matches the query shape (Rails-domain rows first):

| Query shape | First tool | Fallback if empty |
|-------------|------------|-------------------|
| **Rails route** ("what controller handles /foo", "route for X", "list routes") | `mcp__railsMcpServer__get_routes` | `Grep -rn "<path>" config/routes.rb` |
| **Rails model** schema/associations ("model X", "what does X belong_to", "list models") | `mcp__railsMcpServer__analize_models(model_name: "X")` (note: gem misspells `analize`) or `get_models` | `codegraph_search("X")` → Read `app/models/x.rb` |
| **DB schema** / table columns ("columns of table X", "schema for X") | `mcp__railsMcpServer__get_schema(table_name: "X")` | `Grep -n "create_table \"X\"" db/schema.rb` |
| **Controller → view** flow ("views for X controller", "actions of X") | `mcp__railsMcpServer__analyze_controller_views(controller_name: "X")` | `Glob app/views/x/*` + `documentSymbol` on controller |
| **Project / env overview** ("project structure", "env config diff") | `mcp__railsMcpServer__project_info` / `analyze_environment_config` | `codegraph_status` + Read `config/*` |
| Exact symbol name | `codegraph_search(query: "<name>")` | `LSP(operation: "workspaceSymbol", …)` → `Grep -n "<name>"` |
| "who calls X" / "callers of X" | `codegraph_callers(symbol: "<name>")` | LSP `incomingCalls` (needs file:line — find with codegraph_search first) → `Grep -n "<name>("` |
| "what does X call" / "callees of X" | `codegraph_callees(symbol: "<name>")` | LSP `outgoingCalls` → read function body |
| "impact of changing X" | `codegraph_impact(symbol: "<name>")` | — (codegraph-only) |
| "task context for X" / "explain X area" | `codegraph_context(query: "<topic>")` | Grep + Read excerpts |
| Specific file overview | `LSP(operation: "documentSymbol", filePath: …, line: 1, character: 1)` | `Grep "^(class\|module\|def)" <file>` |
| Module / concern / namespace (Ruby) | **Skip CodeGraph** (see caveat). `LSP documentSymbol` on suspected file or `Grep -rn "^module <Name>\b"` | — |
| Pattern matching name (`*retry*`, `validate_*`) | `codegraph_search(query: "<partial>")` | `Grep -rn "def <partial>"` |
| Unknown / open-ended | On a Rails app, `project_info` first to orient, then `codegraph_search`; otherwise `codegraph_search` → `codegraph_context` | Grep last resort |

If the first tool returns hits, **stop**. Don't run fallbacks for fun.

## CodeGraph

CodeGraph is the cheapest tool here — it returns structured `file:line:kind:name` records and supports impact / call-graph queries that Grep can't answer cheaply.

Check `codegraph_status` once at the start of the skill body's logic if you're unsure whether the project is indexed; if `database` is missing or `nodes: 0`, fall straight through to LSP/Grep and note that in the response so the parent knows.

### Ruby caveat

CodeGraph **does not index Ruby `module` declarations** (concerns, namespace modules, mixins). For queries that target a module name (e.g. `find module UrgentBugPin`, `where is concern X included`), skip CodeGraph and use:

- `Grep -rn "^[[:space:]]*module <Name>\b" lib/ app/`
- `Grep -rn "include <Name>\b"` for inclusion sites
- `LSP documentSymbol` on a known file

Mention this in the response when relevant so the parent doesn't second-guess the choice.

## Rails MCP Server (rails-mcp-server)

Optional. Only present when the host project has `gem 'rails-mcp-server'` (dev group) and the server is registered in Claude (default registration name `railsMcpServer`). It answers **Rails-domain** questions that CodeGraph/LSP/Grep can't cheaply: the live route table, model associations + DB-backed schema, controller→view wiring, and resolved environment config — derived from the running Rails app, not raw file scanning.

Use it as the **first tool** for the Rails-specific routing rows above. Pick it over Grep when the query is about *Rails structure* (routes, models, schema, views) rather than an arbitrary symbol.

Tools available (note the gem's exact names):

- `get_routes` — full route table (≈ `rails routes`); maps URL → controller#action
- `analize_models` — **(sic — gem misspells "analyze")** list models, or pass `model_name:` for schema + associations + source
- `get_models` — same payload as `analize_models` (gem ships both; either works)
- `get_schema` — DB schema; pass `table_name:` for one table's columns
- `analyze_controller_views` — controller/action → view relationships; pass `controller_name:` to scope
- `project_info` — Rails version, API-only flag, directory structure
- `analyze_environment_config` — cross-environment config inconsistencies

### Caveats

- **Project-scoped.** rails-mcp-server selects the active project from its own `projects.yml`. If a tool errors with a missing/unknown project, the server isn't pointed at this codebase — note it and fall through to the Grep/Read fallback in the routing table (optionally `switch_project` first if the project name is obvious).
- **Not always installed.** If the `mcp__railsMcpServer__*` tools aren't available or every call errors, the host project simply hasn't wired the gem — silently fall through to the listed fallback and add a one-line note in the response. Never block a discovery on it.
- **Don't dump.** These tools can return large payloads (full model source, every route). Extract `file:line` / table / route lines per the output format; never paste the raw payload into the response.

## LSP

LSP needs a `filePath:line:character` position for most operations. For symbol lookup without a position, use `workspaceSymbol`. For incoming/outgoing calls, first find a definition (CodeGraph or `workspaceSymbol`) to get the position, then call `prepareCallHierarchy` → `incomingCalls` / `outgoingCalls`.

LSP operations available: `goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`, `goToImplementation`, `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`.

LSP shines for:

- Exact references across files (`findReferences`) when you have a position
- File structure overview (`documentSymbol`)
- Workspace-wide symbol search (`workspaceSymbol`) — works for modules too, unlike CodeGraph

## Grep / Glob / Read

Last resort. Use only when CodeGraph and LSP both come up empty, or when the query targets something they can't see (string literals, comments, config files, YAML, Markdown).

- `Grep`: prefer `-n` for `file:line` output, `--include` to scope by extension
- `Glob`: only when you need to enumerate files matching a path pattern — never as the first step of a symbol hunt
- `Read`: only after a hit is located; read with `offset` + `limit` to grab the relevant span, never the whole file

## Output format

Always return this exact shape. The parent should be able to act on it without re-running anything.

```
## Discovery: "<original query>"
- Strategy: <chain you used, e.g. "codegraph_search → LSP workspaceSymbol">
- CodeGraph indexed: <yes/no — note "no" if status check failed or you fell through>

### Matches ({n})
- `<file>:<line>` — `<kind>` — `<name>` — <1-line snippet or signature>
(max 10 matches; if more, append "… and N more — narrow the query")

### Notes (optional)
- One line for each non-obvious caveat (e.g. "module declarations skipped CodeGraph per Ruby caveat", "no exact match — closest neighbors shown", "fallback to Grep because LSP returned no workspace symbol")
```

If there are zero hits anywhere, return:

```
## Discovery: "<query>"
- Strategy: <chain tried>
- Matches: 0

### Suggestion
<one-line suggestion: refine the query, check spelling, try a broader pattern, or use /memory-search for concept queries>
```

## Hard limits

- Max 10 matches in the output; if more exist, say so and recommend narrowing.
- Snippet ≤ 1 line, ~120 chars. If the signature is longer, truncate with `…`.
- Never dump full files into the response. If the parent wants the file, it has the path and line — it can Read with `offset`+`limit`.
- Never include raw CodeGraph / LSP / Grep payloads. Extract `file:line:kind:name`, drop the rest.
- If a CodeGraph or LSP call errors, note it in `Strategy` and move to the next tool; don't surface the raw error unless every tool failed.

## When to chain into another skill instead

If the query is about **why** something was done, a past bug, an architectural decision, or a lesson from memory notes, the right tool is `/memory-search` — not this one. Return a short message:

```
## Discovery: "<query>"
This query is about concepts / decisions / past lessons, not code locations.
Use the `/memory-search` skill instead with the same query.
```
