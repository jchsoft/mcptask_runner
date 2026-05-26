# Cloud Coding Model Substitutes — May 2026

Research date: 2026-05-26
Scope: cloud-hosted coding LLM alternatives to Claude Opus 4.7, focused on releases in the last 20 days (since ~2026-05-06).

## TL;DR

**Primary pick: Qwen 3.7 Max** (released 2026-05-19, 7 days before research date).

- Native Anthropic Messages protocol → drop-in for Claude Code CLI, no wrapper needed
- 1M token context
- 35-hour autonomous run capability
- $2.50 / $7.50 per M tokens (in/out) — roughly 50% off Opus 4.7
- Built to act as drop-in intelligence layer for Claude Code

## Comparison Table

| Model | Released | API $/M (in/out) | Context | SWE-Bench Pro | Anthropic-compat | Note |
|-------|----------|------------------|---------|---------------|------------------|------|
| **Qwen 3.7 Max** | 2026-05-19 | $2.50 / $7.50 | 1M | top tier | native | Drop-in Claude Code, 35h autonomous runs |
| Qwen 3.6 Max-Preview | 2026-04-20 | TBD (preview) | 260K | #1 on 6 benchmarks | yes | Flagship preview, no GA pricing yet |
| Qwen 3.6 Plus | 2026-04 | $0.33 / $1.95 | 1M | strong | yes | Budget tier, 13× cheaper than Opus output |
| Kimi K2.6 | 2026-04-21 | mid-tier | 256K | 58.6 | yes | 300-agent swarm, 12h autonomous runs |
| GLM-5.1 | 2026-04-07 | $1.40 / $4.40 | — | 58.4 (#1 open) | partial | 400 tok/s highspeed variant available |
| DeepSeek V3.2 | earlier | $0.28 / $0.42 | 131K | mid | OpenAI-compat only | Cheapest option, no Anthropic protocol |

Reference: Claude Opus 4.7 is $5.00 / $25.00 per M tokens with 64.3% on SWE-Bench Pro.

## Recommendations by use case

### Primary substitute for Claude Code workflow
**Qwen 3.7 Max** — set `ANTHROPIC_BASE_URL` to Alibaba endpoint, keep Claude Code CLI as-is.
- Suggested first use: triage and autosquash flows where Opus quota is burned heaviest
- Test on read-only triage before letting it write code

### Budget fallback
**Qwen 3.6 Plus** ($0.33 / $1.95) — same Anthropic protocol, 13× cheaper than Opus output.

### Non-Alibaba alternative
**Kimi K2.6** — Anthropic-compatible API, similar SWE-Bench Pro score (58.6), MIT-modified weights so verifiable.

### Skip for now
- **GLM-5.1** — not full Anthropic protocol, more glue code needed
- **DeepSeek V3.2** — OpenAI protocol only, would need Claude Code retool

## Caveats

- None of these match Opus 4.7 on hardest agentic tasks (long-horizon planning, deep multi-file refactors)
- Qwen reportedly "steps back" less by default — may need explicit planning prompts
- Always verify on read-only operations (triage, search) before committing write/edit budget
- Anthropic-compatible mode ≠ identical behavior; some tool-use edge cases differ

## Reasoning model for mcptask_runner runner

For this project specifically, candidates for slotting in as runner model alongside Opus 4.7:

- **Sonnet-tier replacement** for triage (currently Sonnet): Qwen 3.6 Plus
- **Opus-tier replacement** for test repair / heavy work (currently Opus 4.7): Qwen 3.7 Max
- Existing `project_runner_model_caps` memory documents Opus pinned to 4.7 since 2026-05-05 — Qwen 3.7 Max could become a fallback pin if Opus quota exhausted

## Sources

- [Qwen 3.7 Max VentureBeat — 35h autonomous + Claude Code harness](https://venturebeat.com/technology/alibabas-proprietary-qwen3-7-max-can-run-for-35-hours-autonomously-and-supports-external-harnesses-like-anthropics-claude-code)
- [Qwen 3.7 Max developer guide — $2.50/MTok, Anthropic protocol drop-in](https://ofox.ai/blog/qwen3-7-max-developer-guide-2026/)
- [Qwen 3.6 Max in Claude Code — 70% off Opus](https://findskill.ai/blog/qwen-3-6-max-preview-claude-code-tutorial/)
- [Qwen 3.6 vs Claude Opus 4.7 — agentic cost decision May 2026](https://contracollective.com/blog/qwen-3-6-vs-claude-opus-4-7-coding-agentic-tooling)
- [Qwen 3.6-Max-Preview benchmarks](https://www.buildfastwithai.com/blogs/qwen3-6-max-preview-review-2026)
- [Kimi K2.6 release — agentic coding production](https://kimi-k2.org/blog/24-kimi-k2-6-release)
- [Kimi K2.6 Moonshot 256K + 300-agent swarms](https://rits.shanghai.nyu.edu/ai/moonshot-ai-releases-kimi-k2-6-with-256k-context-and-300-agent-swarms/)
- [GLM-5.1 release — #1 SWE-Bench Pro open](https://www.modemguides.com/blogs/ai-news/glm-5-1-open-source-benchmarks-local-ai)
- [GLM-5.1 high-speed API 400 tok/s](https://pandaily.com/zhipu-ai-glm-5.1-high-speed-api-400-tokens-s-may2026)
- [DeepSeek V3.2 OpenRouter pricing](https://openrouter.ai/deepseek/deepseek-v3.2)
- [May 2026 LLM landscape](https://whatllm.org/blog/new-ai-models-may-2026)
- [Best LLM for coding agents — API/tool reliability](https://evolink.ai/blog/best-llm-for-coding-agents-api-cost-reliability)
