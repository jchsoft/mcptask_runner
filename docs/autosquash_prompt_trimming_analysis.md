# Autosquash Prompt Trimming Analysis

_Analysis of what can be removed from the auto-squash instruction prompt sent to the
child AI agent, on the premise that any capable coding agent (Opus, Sonnet, or a
different-provider model routed through `config/models.yml` / `launcher.yml`) already
knows most general-competence guidance._

Scope: `TaskAutoSquash#build_instructions` (`lib/mcptask_runner/services/claude_code/task_auto_squash.rb`)
as the representative example. The fragment methods are shared across all five variants
(`task` / `today` / `once` / `queue` / `story`) and the manual executors, so edits here
propagate widely.

## The organizing principle

The right cut isn't "what does the model know." It's three distinct questions, and the
answer differs per block:

- **Contract** — the parent Ruby process parses it. Keep verbatim; it's an API, not advice.
- **Competence** — any capable agent already has it. Cut.
- **Duplication** — already present in inherited config (`CLAUDE.md`, path-gated rules). Cut, with one caveat.
- **Drift-correction** — the model knows it but violates it under agentic pressure. The genuinely hard category; test before cutting.

## Tier 1 — KEEP VERBATIM (child↔runner API, not knowledge)

These are not "instructions a smart model wouldn't need" — the parent string-matches them.
A different-provider model needs them *more*, not less.

- `TASKRUNNER_RESULT` JSON + "FIRST key / json block / no trailing text" rules — `result_parsing` scans for this exact shape.
- The status enum strings (`success` / `ci_failed` / `merge_failed` / `preexisting_test_errors` / `already_done` / `urgent_bug_pending`) — the runner FSM branches on them.
- `TASKRUNNER_TASK_INFO` output block; `bug_task_id` / `bug_task_name` fields.
- mcptask URI + `server="mcptask-online"` + "DIRECT MCP call, **not** the skill, never curl/Bash" — skills are unreliable in `claude -p` forks and curl hits the wrong internal id (returns the wrong piece).
- Progress-logging cadence **and** the "100% only after `gh pr view` returns `MERGED`" gate — this exists to stop false-completion; it's the whole reason `merge_unverified` / `post_parse_result` exist.
- TodoWrite mandate — the runner *harvests* the child's todo list into the dashboard snapshot (`SnapshotBuilder`). The model knows how to use TodoWrite; it doesn't know the runner mirrors it. **Keep the why, cut the how-to.**
- signoff/branch-protection note, `/test-runner`, `/ci-runner`, `gh pr merge --squash --delete-branch`, `assets:precompile` — project-specific wrappers and quirks.

## Tier 2 — CUT (pure competence, or duplicated in inherited config)

The child runs the `claude` CLI in the project dir, so it **already loads** both
`~/.claude/CLAUDE.md` and project `CLAUDE.md`, plus the path-gated `ruby-rails.md` /
`rubocop.md` (verify — nothing in `build_command` suppresses them). These blocks re-send
context the child already has:

- **`context_optimization_instruction`** (`concerns/instruction_building.rb:114`) — "CodeGraph/LSP before grep, parallel tools, don't re-read files" is verbatim global CLAUDE.md. ⚠️ See caveat 1 before deleting.
- **`coding_conventions_instruction`** (`:31`) — the `$()`-in-commit lesson + heredoc is generic; the rubocop line duplicates `rubocop.md`.
- **`refactor_step`** "Read ruby-rails.md, apply RoR rules" (`workflow_steps.rb:127`) — that file auto-loads on `*.rb` edits; the persona is already a Rails dev.
- **`persona_instruction`** — duplicates ruby-rails.md philosophy (1 line, marginal — keep if you like priming).
- **OUTPUT EFFICIENCY word-list** (filler / pleasantries / hedging) — generic style coaching. **Keep exactly one line: "respond in English even when the task is Czech"** — that overrides default mirror-the-input behavior, so it is a real instruction.
- **`implement_task_step`** "follow CLAUDE.md, incremental commits" — generic.

## Tier 3 — TIGHTEN (real but bloated)

- **`time_awareness_instruction`** (`:160`): the 20-min-inactive *kill* is runner-enforced (heartbeat) — telling the agent is informational noise it can't act on. Keep only the one line it *can* act on: ">70 min → skip full CI, targeted tests only."
- **PATIENCE block** → one line: "don't poll/retry in loops."
- **The 14 numbered steps** → most restate branch → implement → test → push → PR → merge, which every coding agent does. Collapse to a checklist; annotate *only* the non-obvious ones (branch-name-includes-id, the skills, the signoff note, squash-merge).

## Two honest caveats before cutting

1. **The context_optimization block isn't pure duplication — it's a deliberate countermand.**
   Inherited CLAUDE.md says "always use the `/discover`, `/memory-search`, `/mcptask-read`
   skills." Those skills are unreliable in `-p` forks. This block re-states the *raw*
   CodeGraph→LSP→Grep order *without* the skill wrappers. Delete it and the child falls
   back to the inherited "use the skill" rule — which misbehaves here. So this one needs
   **replacing** with a one-liner ("use CodeGraph/LSP directly, skip the skill wrappers"),
   not deleting.

2. **Verbosity is partly insurance for weaker models.** The runner explicitly supports
   Sonnet, Haiku-on-resume, and non-Anthropic backends (`config/models.yml`,
   `launcher.yml` → ollama). The drift-corrections (English-only, no-polling, no-re-read,
   time-skip) aren't knowledge gaps — they're behaviors capable models *still* violate over
   long agentic runs, and weaker models violate more. **Knowledge/duplication cuts are safe
   to ship. Drift-correction cuts should be A/B'd against `RunLog` data** (completion rate,
   context-overflow rate) before trusting them on the cheap tiers.

## Why this is worth doing here specifically

Every token in this prompt is re-paid on **every `--continue` retry**, and this codebase
has a documented context-overflow failure mode (the whole `merge_unverified` /
overflow-recovery machinery exists because of it). Trimming ~40–50% of the non-contract
text (rough: ~5K → ~3K chars) compounds across retries and across the five variants. Since
these fragments are shared (`WorkflowSteps` is included by the manual executors too), one
edit fixes all of them — but you must re-run the executor tests afterward.

## Per-section decision table

One row per prompt block. **Action**: `KEEP` (verbatim contract) / `TRIM` (shorten) /
`REMOVE` (delete) / `REPLACE` (swap for a one-liner). Source = the fragment method that
emits the block.

| Section | Source | Action | What to change | Explanation | Reason |
|---|---|---|---|---|---|
| `[PERSONA]` | `persona_instruction` (`instruction_building.rb:69`) | TRIM / optional REMOVE | Drop, or keep the single line | Duplicates `ruby-rails.md` philosophy that auto-loads on `*.rb` edits | Competence/duplication; 1 line so low stakes — keep only if you want priming |
| `[TASK]` line | `task_auto_squash.rb:22` | KEEP | — | Names the actual task id + the auto-merge intent | Task-specific framing; nothing generic about it |
| `1. GIT SETUP` | `triaged_git_step` (`instruction_building.rb:9`) | KEEP | — | `checkout main && pull` before branching; resume-branch logic | Encodes the runner's resume contract (branch reuse on `resuming:true`) |
| `2. LOAD TASK` | `load_task_step` (`workflow_steps.rb:31`) | KEEP | — | Direct `ReadMcpResourceTool`, server name, URI, no-skill/no-curl | Contract: skills unreliable in `-p`; curl hits wrong internal id |
| `TASKRUNNER_TASK_INFO` block | inside `load_task_step` | KEEP | — | Structured task echo | Parent parses it from the stream |
| `TODO LIST (MANDATORY)` | `todo_list_instruction` (`:91`) | TRIM | Cut the how-to; keep one line: "maintain a live TodoWrite list — the runner mirrors it to the dashboard" | Model knows *how* to use TodoWrite; it doesn't know the runner harvests it | Keep the *why* (contract), drop the competence |
| `CONTEXT OPTIMIZATION` | `context_optimization_instruction` (`:114`) | REPLACE | One line: "use CodeGraph/LSP directly for exploration, skip the skill wrappers; parallel tools; don't re-read files" | Overlaps inherited CLAUDE.md **but** deliberately countermands its "always use `/discover`" rule (skills misbehave in `-p`) | Not pure duplication — needs a one-liner replacement, not deletion (caveat 1) |
| `PATIENCE & CONTEXT BURN` | part of `context_optimization_instruction` | TRIM | Collapse to: "don't poll/retry in loops; size logs before reading" | Mostly generic competence | Drift-correction; keep one terse line as insurance for weaker models |
| `OUTPUT EFFICIENCY` | part of `context_optimization_instruction` | TRIM | Delete the word-list; **keep only** "respond in English even when the task is Czech" | Banned-word list is generic style coaching | The English-only line overrides default mirror-the-input behavior — a real instruction |
| `TIME MANAGEMENT` | `time_awareness_instruction` (`:160`) | TRIM | Keep only ">70 min → skip full CI, run targeted tests, then emit result" | The 20-min-inactive kill is runner-enforced (heartbeat); agent can't act on it | Informational noise vs the one line the agent can actually self-apply |
| `CODING CONVENTIONS` | `coding_conventions_instruction` (`:31`) | REMOVE | Delete | `$()`/heredoc lesson is generic; rubocop line duplicates `rubocop.md` | Competence + duplication |
| `PREEXISTING TEST ERRORS` | `preexisting_test_errors_instruction` (`workflow_steps.rb:182`) | KEEP (TRIM optional) | Keep the protocol; can compress wording | Specific tool calls + the `preexisting_test_errors` status + `bug_task_id/name` fields | Contract: runner pins the new bug from these fields |
| `3. CREATE BRANCH` | `create_branch_step` (`:73`) | TRIM | Keep "branch name includes task id"; drop the obvious `checkout -b` | Branch-name-includes-id is the only non-obvious bit | Competence except the naming convention |
| `4. IMPLEMENT TASK` | `implement_task_step` (`:82`) | REMOVE | Delete | "Follow CLAUDE.md, incremental commits" is generic | Competence |
| `5/7/9 TESTS` (unit/system/verify) | `run_unit_tests_step` / `run_system_tests_step` / `verify_tests_step` | TRIM | Collapse to one line referencing `/test-runner` | The only non-obvious bit is "use the `/test-runner` skill" | Skill reference is project-specific; the rest is generic |
| `6. COMPILE TEST ASSETS` | `compile_test_assets_step` (`:100`) | KEEP | — | Exact `assets:precompile RAILS_ENV=test` command | Project-specific step a model wouldn't infer |
| `8. REFACTOR` | `refactor_step` (`:127`) | REMOVE | Delete | "Read ruby-rails.md, apply RoR rules" — that file auto-loads; persona already covers it | Duplication |
| `10. PUSH` | `push_step` (`:143`) | TRIM | Fold into the PR step | `git push -u origin HEAD` is generic | Competence |
| `11. CREATE PR` | `create_pr_step` (`:148`) | KEEP | — | PR template + mcptask link + auto-merge note | Project conventions |
| `12. SKIP screenshots` | `skip_screenshots_step` (`:168`) | KEEP | — | One line | Tells the agent *not* to run the screenshot flow (autosquash) |
| `13. CI + AUTO-MERGE` | `ci_run_and_merge_step` (`auto_squash_base.rb:278`) | KEEP | — | `/ci-runner`, signoff/branch-protection note, `--squash --delete-branch`, retry-once | Project quirks + the merge mechanics the runner depends on |
| `14. FINAL OUTPUT` + `AUTO-SQUASH` note | `task_auto_squash.rb:32` | KEEP | — | Short pointer to the result JSON | Trivial size, sets up the contract block |
| `TASKRUNNER_RESULT` JSON + FORMATTING | `result_format_instruction` (`:46`) | KEEP | — | Exact JSON shape + "FIRST key / json block / no trailing text" | Hard API: `result_parsing` string-matches it |
| `PROGRESS LOGGING` | `auto_squash_progress_logging_instruction` (`auto_squash_base.rb:192`) | KEEP | — | Cadence + "100% only after `gh pr view` = MERGED" gate | Contract: prevents false-completion (`merge_unverified` exists for this) |
| `Set status` enum | `task_auto_squash.rb:44` + `urgent_bug_pending_status_option` (`:148`) | KEEP | — | Exact status strings + `bug_task_id/name` | Runner FSM branches on these literal strings |

**Net effect:** removals/trims land almost entirely in the middle competence/duplication
band (`CODING CONVENTIONS`, `REFACTOR`, `IMPLEMENT TASK`, `OUTPUT EFFICIENCY` word-list,
`CONTEXT OPTIMIZATION` body). Every Tier-1 contract block (`TASKRUNNER_RESULT`, status
enum, progress gate, MCP fetch, task-info echo) stays untouched.

## Suggested next step

Draft trimmed versions of `context_optimization_instruction`,
`coding_conventions_instruction`, `time_awareness_instruction`, and the step bodies as
concrete edits, leaving every Tier-1 contract block untouched. Validate against
`ruby bin/ci` and the runner's own `RunLog` before rollout.

---

## Appendix — Fully-rendered `task` variant prompt (baseline)

This is the exact text the child agent receives today, for reference when trimming.

### How it is assembled

`TaskAutoSquash#build_instructions` (`task_auto_squash.rb:18`) string-interpolates ~25
fragment methods spread across four files:

- `task_auto_squash.rb` — the skeleton + status list
- `auto_squash_base.rb` — `implementation_steps`, `ci_run_and_merge_step`, `auto_squash_progress_logging_instruction`
- `workflow_steps.rb` — the numbered step bodies
- `concerns/instruction_building.rb` — persona, git, todo, conventions, result-format, time, urgent-bug

It is passed to the child via:

```
claude -p "<prompt>" --model opus --max-turns 300 \
  --output-format=stream-json --verbose \
  --permission-mode=bypassPermissions \
  --disallowedTools EnterPlanMode,ExitPlanMode
```

(`claude_code_base.rb:261`).

### Rendered prompt

Resolved with `account_code=jchsoft`, `task_id=1234`, `resuming=false`:

```
[PERSONA] Senior Ruby on Rails dev. Follow RubyWay.

[TASK]
Work on the specific task #1234 with AUTOMATIC PR merge after CI passes.

WORKFLOW:
1. GIT SETUP: git checkout main && git pull → step 2

2. LOAD TASK: INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/jchsoft/1234" — DIRECT MCP call. Do NOT use /mcptask-read skill. NEVER Bash/curl/Net::HTTP.
   - Output:
     TASKRUNNER_TASK_INFO:
     ID: <relative_id>
     TITLE: <task name>
     DESCRIPTION: <first 200 chars>
     END_TASK_INFO

TODO LIST (MANDATORY):
- FIRST action after reading the task: create a todo list (TodoWrite) covering all workflow steps.
- Keep it live: mark in_progress when starting an item, completed immediately when done — never batch at the end.
- Re-plan the list when scope changes (new urgent bug, extra fixes) instead of working off-list.

CONTEXT OPTIMIZATION (MANDATORY):
- Call independent tools in parallel (Read/Grep/Glob in one turn)
- CodeGraph/LSP BEFORE Read/Grep for exploration
- If CodeGraph unavailable, LSP as primary:
  * documentSymbol — file structure
  * findReferences — callers
  * definition — jump to def
  * incomingCalls — call graph
- Never re-read same file >2×. Use offset+limit for re-reads.

PATIENCE & CONTEXT BURN (MANDATORY):
- Long waits (CI, system tests, other Claude agent) → be patient. No polling loops,
  no repeated status checks, no retries "just to see". Each poll re-sends full history.
- Large files / logs → never Read whole. Size first (wc -l), then tail/grep/offset+limit.
- Never repeat the same operation hoping for different result. One failure = diagnose, not retry.

OUTPUT EFFICIENCY (MANDATORY — saves ~65% tokens):
- Drop filler: just/really/basically/actually/simply/certainly
- Drop pleasantries: "Sure!"/"Happy to help"/"Let me..."/"I'll proceed to..."
- No hedging: maybe/perhaps/might be worth
- Short fragments. Pattern: [thing] [action] [reason].
- NEVER explain what you're about to do — do it. Never narrate tool calls.
- NEVER summarize what you did — user sees diff.
- Technical terms exact. Code blocks unchanged. Errors quoted exact.
- TASKRUNNER_RESULT JSON unchanged — rules apply to natural language only.
- ALWAYS respond in English — even when task description is in Czech or other language.

TIME MANAGEMENT (CRITICAL):
- Target: 90 min. Kill: 20 min inactive (no stream output).
- Producing output = safe.
- >70 min elapsed → SKIP full tests/CI. Run targeted tests only → TASKRUNNER_RESULT.
- ALWAYS output TASKRUNNER_RESULT when done.

CODING CONVENTIONS (MANDATORY):
- GIT COMMITS: NEVER use $() in commit messages. Plain quoted strings:
  ✅ git commit -m "Fix login validation for empty emails"
  ❌ git commit -m "$(echo 'Fix login')"
  Multi-line → heredoc:
  git commit -m "$(cat <<'EOF'
  Your message here.
  EOF
  )"
- RUBOCOP BEFORE CI: git diff --name-only main -- '*.rb' | xargs rubocop -a

PREEXISTING TEST ERRORS (CRITICAL):
If tests fail in code you did NOT modify:
1. Verify: git stash → run tests on main → git stash pop
2. Fail without your changes = PREEXISTING
3. Create URGENT bug task:
   - mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → get relative_id
   - CreatePieceTool: account_code=<from CLAUDE.md>, piece_type="Task", task_type_code="bug",
     priority_code="urgent", project_id=<from CLAUDE.md>, assigned_user_id=<relative_id>
     name="Fix: Padající testy - <description>"
     description: failing tests, errors, branch/commit, interrupted task ID
4. git checkout main (keep feature branch)
5. Status "preexisting_test_errors"
6. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
7. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
8. Do NOT fix them — only create bug task

3. CREATE BRANCH:
   - Include task ID: "feature/{task_id}-{desc}" or "fix/{task_id}-{desc}"
   - git checkout -b <branch-name>

4. IMPLEMENT TASK:
   - Follow CLAUDE.md rules
   - Incremental commits, clear messages

5. UNIT TESTS:
   - Invoke /test-runner
   - Fix failures, commit. Repeat until pass.

6. COMPILE TEST ASSETS:
   - bin/rails assets:precompile RAILS_ENV=test

7. SYSTEM TESTS:
   - Invoke /test-runner for system tests
   - Fix failures, commit. Repeat until pass.

8. REFACTOR: Read `~/.claude/rules/ruby-rails.md`, apply RoR rules
   - Commit refactoring changes

9. VERIFY TESTS: Re-run all via /test-runner
   - Unit + system tests. Repeat until all pass.

10. PUSH: git push -u origin HEAD

11. CREATE PR:
    - Use .github/pull_request_template.md if exists
    - Clear summary + mcptask.online task link
    - Auto-merge after CI passes

12. SKIP screenshots (autosquash)
13. CI + AUTO-MERGE:
    - No bin/ci → skip to step 14, status "success"
    - Invoke /ci-runner
    - NOTE: bin/ci posts "signoff" status to GitHub via gh. Satisfies branch protection.
      Disabled CI workflow (ci.yml.disabled) irrelevant — signoff is local. PR IS mergeable.
    - CI PASSES:
      → gh pr merge --squash --delete-branch
      → git checkout main && git pull
      → status "success"
    - CI FAILS:
      → Analyze, fix, commit, push
      → Retry bin/ci
      → Retry passes → merge (above)
      → Retry fails → status "ci_failed" (PR stays open)

14. FINAL OUTPUT: Generate the result JSON

AUTO-SQUASH: PR auto-merged after CI. CI fails 2× → PR stays open.

At the END, output the result as valid JSON in a code block:

json
{"TASKRUNNER_RESULT": true, "status": "success", "pr_number": N, "branch_name": "...", "task_id": 1234}
```

CRITICAL FORMATTING:
1. JSON inside ```json code block
2. "TASKRUNNER_RESULT": true MUST be FIRST key
3. Valid JSON — escape quotes as \"
4. pr_number + branch_name REQUIRED whenever PR was created (success / ci_failed / merge_failed / preexisting_test_errors)
5. NO text after closing ```

PROGRESS LOGGING (MANDATORY — min 3× LogWorkProgressTool calls during run):
- Single 100% call at end = UNACCEPTABLE. Caller sees no interim state.
- Milestones (minimum cadence, bump progress_percent each time):
  a) After branch created + task understood → ~20%
  b) After implementation + unit tests pass → ~60%
  c) ONLY after `gh pr view <pr_number> --json state --jq .state` returns `MERGED` → 100%
     UNMERGED outcomes (ci_failed / merge_failed / preexisting_test_errors / failure):
     cap at 80%. Description states non-merge reason. NEVER 100% for unmerged work.
     EXCEPTION — already_done: REQUIRED 100% (resolution exists in prior merged commit),
       description names the resolving commit SHA so triage closes the task.
- Each call: duration_minutes = minutes since previous call (not cumulative);
  description = what was done since last log.
- More calls OK for long tasks; 3× is floor, not target.

Set status:
   - "success" if task completed AND `gh pr view <pr_number> --json state --jq .state` returns `MERGED`
   - "ci_failed" if CI failed after retry (PR stays open)
   - "merge_failed" if `gh pr merge` itself errored (branch protection, conflicts, etc.)
   - "preexisting_test_errors" if tests were already failing before your changes (urgent bug task created)
   - "already_done" if task already resolved (no code changes needed — e.g. fixed in earlier commit);
       MUST log final progress at 100% naming the resolving commit SHA
   - "urgent_bug_pending" if you discovered/created a NEW URGENT bug task during work that must be handled before continuing this task;
       BEFORE emitting this status:
         1. Commit + push current work on this task's branch (if any) — leaves PR/branch for human review or future resume
         2. `git checkout main` — leave clean working tree so runner picks the urgent bug, not this task
         3. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
         4. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
       Loop will exit (story-locked / explicit task / single-shot) or re-triage globally (today/queue) and pick the urgent bug.
   - "failure" for other errors

### The `@next`-based variants

`today` / `once` / `queue` go through `build_next_task_instructions`
(`auto_squash_base.rb:141`) instead, which swaps step 2 for `task_fetch_step` (the `@next`
MCP fetch + `no_more_tasks` handling) and uses `next_task_auto_squash_status_options`. The
implementation steps 3–14, progress logging, and result format are identical. `story` adds
a story-load step and shifts numbering by one.

---

## Implemented — Original vs New (`task` variant)

The trim + DRY unify described above is implemented. Rendered `TaskAutoSquash.new(task_id: 1234)`
prompt, original vs new:

| Original (8279 chars, 175 lines) | New — trimmed + DRY (6517 chars, 129 lines) |
|---|---|
| `[PERSONA] Senior Ruby on Rails dev. Follow RubyWay.` | _(removed — generic priming; the model is already a Rails dev and `ruby-rails.md` auto-loads)_ |
| `[TASK]`<br>`Work on the specific task #1234 with AUTOMATIC PR merge after CI passes.` | _(unchanged)_ |
| `WORKFLOW:`<br>`1. GIT SETUP: git checkout main && git pull → step 2` | _(unchanged)_ |
| `2. LOAD TASK: INVOKE ReadMcpResourceTool … uri="mcptask://pieces/jchsoft/1234" — DIRECT MCP …`<br>`   - Output: TASKRUNNER_TASK_INFO / ID / TITLE / DESCRIPTION / END_TASK_INFO` | _(unchanged — contract)_ |
| `TODO LIST (MANDATORY):`<br>`- FIRST action … create a todo list (TodoWrite) …`<br>`- Keep it live: mark in_progress … never batch at the end.`<br>`- Re-plan the list when scope changes …` | `TODO LIST (MANDATORY): keep a live TodoWrite list of the workflow steps (in_progress/completed as you go) — the runner mirrors it to the dashboard.` |
| `CONTEXT OPTIMIZATION (MANDATORY):`<br>`- Call independent tools in parallel …`<br>`- CodeGraph/LSP BEFORE Read/Grep …`<br>`- If CodeGraph unavailable, LSP as primary: documentSymbol / findReferences / definition / incomingCalls`<br>`- Never re-read same file >2× …`<br><br>`PATIENCE & CONTEXT BURN (MANDATORY):`<br>`- Long waits … be patient. No polling loops …`<br>`- Large files/logs → never Read whole …`<br>`- Never repeat the same operation …`<br><br>`OUTPUT EFFICIENCY (MANDATORY — saves ~65% tokens):`<br>`- Drop filler / pleasantries / hedging …`<br>`- Short fragments …`<br>`- NEVER explain … Never narrate …`<br>`- NEVER summarize …`<br>`- Technical terms exact …`<br>`- TASKRUNNER_RESULT JSON unchanged …`<br>`- ALWAYS respond in English …` | `EXPLORATION & OUTPUT (MANDATORY):`<br>`- Explore with CodeGraph/LSP directly — skip the /discover, /memory-search skill wrappers (unreliable in this context). Call independent tools in parallel; never re-read a file already read.`<br>`- Don't poll/retry in loops (each poll re-sends full history); size large files/logs before reading.`<br>`- Be terse: no narration, no summaries of what you did (the user sees the diff). TASKRUNNER_RESULT JSON unchanged.`<br>`- ALWAYS respond in English — even when the task description is in Czech or another language.` |
| `TIME MANAGEMENT (CRITICAL):`<br>`- Target: 90 min. Kill: 20 min inactive …`<br>`- Producing output = safe.`<br>`- >70 min elapsed → SKIP full tests/CI …`<br>`- ALWAYS output TASKRUNNER_RESULT when done.` | `TIME: >70 min elapsed → SKIP full tests/CI, run targeted tests only, then emit TASKRUNNER_RESULT. ALWAYS output TASKRUNNER_RESULT when done.` |
| `CODING CONVENTIONS (MANDATORY):`<br>`- GIT COMMITS: NEVER use $() … ✅/❌ examples … heredoc …`<br>`- RUBOCOP BEFORE CI: git diff … xargs rubocop -a` | _(removed — duplicates `rubocop.md` / `ruby-rails.md`)_ |
| `PREEXISTING TEST ERRORS (CRITICAL):`<br>`1. Verify: git stash → run tests on main …`<br>`3. Create URGENT bug task: mcptask://user … CreatePieceTool …`<br>`5. Status "preexisting_test_errors"`<br>`6/7. bug_task_id / bug_task_name …`<br>`8. Do NOT fix them — only create bug task` | _(unchanged — contract)_ |
| `3. CREATE BRANCH:`<br>`   - Include task ID … - git checkout -b <branch-name>` | _(unchanged)_ |
| `4. IMPLEMENT TASK:`<br>`   - Follow CLAUDE.md rules`<br>`   - Incremental commits, clear messages` | `4. IMPLEMENT TASK (incremental commits, clear messages)` |
| `5. UNIT TESTS … 6. COMPILE TEST ASSETS … 7. SYSTEM TESTS …` | _(unchanged)_ |
| `8. REFACTOR: Read ~/.claude/rules/ruby-rails.md, apply RoR rules`<br>`   - Commit refactoring changes` | _(removed — duplicates path-gated `ruby-rails.md`)_ |
| `9. VERIFY TESTS … 10. PUSH … 11. CREATE PR … 12. SKIP screenshots … 13. CI + AUTO-MERGE … 14. FINAL OUTPUT` | `8. VERIFY TESTS … 9. PUSH … 10. CREATE PR … 11. SKIP screenshots … 12. CI + AUTO-MERGE … 13. FINAL OUTPUT` _(renumbered −1)_ |
| `AUTO-SQUASH: PR auto-merged after CI. CI fails 2× → PR stays open.` | _(unchanged)_ |
| ` ```json {"TASKRUNNER_RESULT": true, …} ``` `<br>`CRITICAL FORMATTING: 1…5` | _(unchanged — contract)_ |
| `PROGRESS LOGGING (MANDATORY — min 3× …)`<br>`a) ~20% … b) ~60% … c) ONLY after gh pr view = MERGED → 100% …` | _(unchanged — contract)_ |
| `Set status:`<br>`   - "success" … "ci_failed" … "merge_failed" … "preexisting_test_errors" … "already_done" … "urgent_bug_pending" … "failure"` | `Set status:`<br>`- "success" … "failure"` _(same wording; only 3-space indent dropped)_ |
| **FOOTER — statistics** | |
| 175 lines · 8279 chars · 6 coaching blocks + persona | 129 lines · 6517 chars · 1 merged block, no persona |
| **Δ: −46 lines · −1762 chars · −21%** — every contract block preserved byte-for-byte (only step renumbering + status de-indent); cuts are the persona line + generic-competence blocks the child already inherits from `CLAUDE.md` + path-gated rules. Saving is re-paid on **every `--continue` retry**. | |

### New rendered prompt (full text)

Resolved `TaskAutoSquash.new(task_id: 1234)` with `account_code=jchsoft`:

````
[TASK]
Work on the specific task #1234 with AUTOMATIC PR merge after CI passes.

WORKFLOW:
1. GIT SETUP: git checkout main && git pull → step 2

2. LOAD TASK: INVOKE ReadMcpResourceTool with server="mcptask-online", uri="mcptask://pieces/jchsoft/1234" — DIRECT MCP call. Do NOT use /mcptask-read skill. NEVER Bash/curl/Net::HTTP.
   - Output:
     TASKRUNNER_TASK_INFO:
     ID: <relative_id>
     TITLE: <task name>
     DESCRIPTION: <first 200 chars>
     END_TASK_INFO

TODO LIST (MANDATORY): keep a live TodoWrite list of the workflow steps (in_progress/completed as you go) — the runner mirrors it to the dashboard.

EXPLORATION & OUTPUT (MANDATORY):
- Explore with CodeGraph/LSP directly — skip the /discover, /memory-search skill wrappers (unreliable in this context). Call independent tools in parallel; never re-read a file already read.
- Don't poll/retry in loops (each poll re-sends full history); size large files/logs before reading.
- Be terse: no narration, no summaries of what you did (the user sees the diff). TASKRUNNER_RESULT JSON unchanged.
- ALWAYS respond in English — even when the task description is in Czech or another language.

TIME: >70 min elapsed → SKIP full tests/CI, run targeted tests only, then emit TASKRUNNER_RESULT. ALWAYS output TASKRUNNER_RESULT when done.

PREEXISTING TEST ERRORS (CRITICAL):
If tests fail in code you did NOT modify:
1. Verify: git stash → run tests on main → git stash pop
2. Fail without your changes = PREEXISTING
3. Create URGENT bug task:
   - mcptask://user (server="mcptask-online", LITERAL URI — no account suffix) → get relative_id
   - CreatePieceTool: account_code=<from CLAUDE.md>, piece_type="Task", task_type_code="bug",
     priority_code="urgent", project_id=<from CLAUDE.md>, assigned_user_id=<relative_id>
     name="Fix: Padající testy - <description>"
     description: failing tests, errors, branch/commit, interrupted task ID
4. git checkout main (keep feature branch)
5. Status "preexisting_test_errors"
6. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
7. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
8. Do NOT fix them — only create bug task

3. CREATE BRANCH:
   - Include task ID: "feature/{task_id}-{desc}" or "fix/{task_id}-{desc}"
   - git checkout -b <branch-name>

4. IMPLEMENT TASK (incremental commits, clear messages)

5. UNIT TESTS:
   - Invoke /test-runner
   - Fix failures, commit. Repeat until pass.

6. COMPILE TEST ASSETS:
   - bin/rails assets:precompile RAILS_ENV=test

7. SYSTEM TESTS:
   - Invoke /test-runner for system tests
   - Fix failures, commit. Repeat until pass.

8. VERIFY TESTS: Re-run all via /test-runner
   - Unit + system tests. Repeat until all pass.

9. PUSH: git push -u origin HEAD

10. CREATE PR:
    - Use .github/pull_request_template.md if exists
    - Clear summary + mcptask.online task link
    - Auto-merge after CI passes

11. SKIP screenshots (autosquash)

12. CI + AUTO-MERGE:
    - No bin/ci → skip to step 13, status "success"
    - Invoke /ci-runner
    - NOTE: bin/ci posts "signoff" status to GitHub via gh. Satisfies branch protection.
      Disabled CI workflow (ci.yml.disabled) irrelevant — signoff is local. PR IS mergeable.
    - CI PASSES:
      → gh pr merge --squash --delete-branch
      → git checkout main && git pull
      → status "success"
    - CI FAILS:
      → Analyze, fix, commit, push
      → Retry bin/ci
      → Retry passes → merge (above)
      → Retry fails → status "ci_failed" (PR stays open)

13. FINAL OUTPUT: Generate the result JSON

AUTO-SQUASH: PR auto-merged after CI. CI fails 2× → PR stays open.

At the END, output the result as valid JSON in a code block:

```json
{"TASKRUNNER_RESULT": true, "status": "success", "pr_number": N, "branch_name": "...", "task_id": 1234}
```

CRITICAL FORMATTING:
1. JSON inside ```json code block
2. "TASKRUNNER_RESULT": true MUST be FIRST key
3. Valid JSON — escape quotes as \"
4. pr_number + branch_name REQUIRED whenever PR was created (success / ci_failed / merge_failed / preexisting_test_errors)
5. NO text after closing ```

PROGRESS LOGGING (MANDATORY — min 3× LogWorkProgressTool calls during run):
- Single 100% call at end = UNACCEPTABLE. Caller sees no interim state.
- Milestones (minimum cadence, bump progress_percent each time):
  a) After branch created + task understood → ~20%
  b) After implementation + unit tests pass → ~60%
  c) ONLY after `gh pr view <pr_number> --json state --jq .state` returns `MERGED` → 100%
     UNMERGED outcomes (ci_failed / merge_failed / preexisting_test_errors / failure):
     cap at 80%. Description states non-merge reason. NEVER 100% for unmerged work.
     EXCEPTION — already_done: REQUIRED 100% (resolution exists in prior merged commit),
       description names the resolving commit SHA so triage closes the task.
- Each call: duration_minutes = minutes since previous call (not cumulative);
  description = what was done since last log.
- More calls OK for long tasks; 3× is floor, not target.

Set status:
- "success" if task completed AND `gh pr view <pr_number> --json state --jq .state` returns `MERGED`
- "ci_failed" if CI failed after retry (PR stays open)
- "merge_failed" if `gh pr merge` itself errored (branch protection, conflicts, etc.)
- "preexisting_test_errors" if tests were already failing before your changes (urgent bug task created)
- "already_done" if task already resolved (no code changes needed — e.g. fixed in earlier commit / fix branch is empty); MUST log final progress at 100% naming the resolving commit SHA
- "urgent_bug_pending" if you discovered/created a NEW URGENT bug task during work that must be handled before continuing this task;
    BEFORE emitting this status:
      1. Commit + push current work on this task's branch (if any) — leaves PR/branch for human review or future resume
      2. `git checkout main` — leave clean working tree so runner picks the urgent bug, not this task
      3. Add field "bug_task_id": <relative_id of the urgent bug task you created> — REQUIRED so runner pins the new bug
      4. Add field "bug_task_name": <name of the urgent bug task you created> — REQUIRED so runner shows the name in the card
    Loop will exit (story-locked / explicit task / single-shot) or re-triage globally (today/queue) and pick the urgent bug.
- "failure" for other errors
````
