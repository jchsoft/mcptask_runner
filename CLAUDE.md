## Finding Information

| Information type | Tool | Example |
|------------------|------|---------|
| **Symbols** (classes, methods) | CodeGraph (`mcp__codegraph__*`) | "find `WorkLoop`" |
| **Modules, concerns, mixins** | **LSP** `documentSymbol` or `Grep` | `module InstructionBuilding` |
| **File structure** (all symbols) | **LSP** `documentSymbol` | complete overview of classes, modules, methods |
| **Who calls/references a symbol** | **LSP** `findReferences` / `incomingCalls` | precise references from known position |
| **Architecture, patterns, lessons learned** | `/memory-search` skill | "how does triage work?" |

**LSP tool available** (ruby-lsp plugin) — sees modules, concerns, everything CodeGraph misses. Needs file:line position, so find file via CodeGraph/Grep first, then analyze via LSP.
**CodeGraph Ruby limitation:** No `module` indexing (concerns, namespace modules).

## LLM Memory Notes MCP Usage
- Memory identifier: `wv-runner` (architecture, patterns, commands, testing info)
- **Search**: `/memory-search` skill (Haiku, compact filtered results)
- **No direct `ReadMcpResourceTool`** for search — too verbose in context

## mcptask.online
- Project name is: "McpTask rails runner"
- project_relative_id=69
- account_code: `jchsoft`

## Large File Token Cost Prevention
- **Read big file (>200 lines) once.** Then `offset`+`limit` only.
- **Batch edits.** All changes to same file = one turn. Each turn re-sends full conversation history.
- **File >500 lines?** Split first, edit smaller parts.
- **$2 → $17 disaster:** repeated large-file edits = re-sent file content each turn = 8× cost.

## CI & Quality Checks
- **Full CI**: `ruby bin/ci` — all checks (tests, RuboCop, Reek, Flay)
- **Tests only**: `ruby test_runner.rb`
- **Individual tests**: `ruby -I lib -I test test/services/<test_file>.rb`
- **All checks must pass before commit**

## Version Management
**Important**: After completing mcptask_runner task (code committed and ready):
- Run: `ruby bin/increment_version.rb` to increment mcptask_runner version by 0.1
- Only increments mcptask_runner version, not projects where runner used
- Version file: `lib/mcptask_runner/version.rb`
- Current version displayed at startup
- Pattern: 0.1.0 → 0.1.1 → 0.1.2 → ... → 0.1.9 → 0.2.0 → 0.2.1 → etc
- Run AFTER code changes committed
- Example: implement feature, commit code, then run `ruby bin/increment_version.rb` before ending task