# Follow-up Plan 1 — Maximising the local agents

Goal: turn the working stack (Glimmer + GPT-OSS proven agentic, opencode +
Continue wired, demos passing) from "capable" into "hard to beat". Ordered
by payoff; each step is independently shippable.

Baseline (verified 2026-09-25): 7 models in Ollama, both new models emit
real `tool_calls` via `:11434/v1` at full 131K context, opencode smoke test
passes on Glimmer, Continue Agent works with pinned tool-name rules.

## Step 1 — Eval harness (baseline everything, first)

Why first: every later change needs a before/after score. Judging by feel
stops here.

- New script (e.g. `eval.sh`): for each agentic model
  (`muse-glimmer:30b-mlx`, `gpt-oss:120b`, `qwen3-coder:30b`), run demos
  01–03 end to end via `opencode run`, then the demo `check.py` graders.
- Record per model per demo: pass/fail, wall time, approximate tokens
  (from `opencode run --format json` event stream). Append to a dated
  results file, e.g. `eval-results-<date>.md`.
- Acceptance: one command produces a full pass/fail matrix for all three
  models; re-running is safe (demos reset or tolerate re-runs).

## Step 2 — Close the retrieval gap

Agents today see only what fits in context; demo 03 is manual and
Continue `@codebase` indexing is disabled (`disableIndexing: true`).

- Re-enable Continue indexing (remove the disable flag, let first-use
  indexing complete on the workspace).
- Expose Qdrant retrieval inside the agent loop: prefer an MCP server
  (works for both opencode and Continue via `mcpServers`); a thin script
  tool (`rag_demo.py --collection … --query …`) is the fallback.
- Evaluate an embedding upgrade (`nomic-embed-text` → `bge-m3` or
  `qwen3-embedding`): re-ingest one collection, compare demo 03 scores
  using the Step 1 harness before switching over.
- Acceptance: demo 03 completable by the agent alone (no manual
  ingest/query/paste step); `@codebase` answers over the workspace.

## Step 3 — Add MCP servers (tool depth)

Files + terminal only goes so far; target "does the whole task".

- Candidates: web fetch, GitHub, persistent memory, sequential-thinking,
  time. Start with fetch + thinking (highest demo-02 leverage).
- Configure in both harnesses (opencode config + Continue `mcpServers`),
  one server at a time, re-running affected demos after each.
- Acceptance: demo 02 research loop runs stronger/faster with fetch;
  no regressions in 01/03 per the harness.

## Step 4 — Align limits and residency (free performance)

- opencode `limit.context` is 32768 while models serve 131K: raise the
  default limit in `configs/opencode-ollama-provider.json` and
  `configs/opencode-client-defaults.json` (e.g. 65536+) and regenerate
  the provider(s).
- Keep-alive is 5 min; a 120B reload mid-task is slow. Raise
  `OLLAMA_KEEP_ALIVE` (e.g. 30m–24h to taste) and preload the working
  pair (Glimmer + embed/coder) so agent loops never cold-start.
- Acceptance: `ollama ps` shows the pair resident across tasks; long
  agent runs show no mid-task reload stalls.

## Step 5 — Repo instructions + autonomy

- Add `AGENTS.md` (conventions, tool pins, demo workflow) plus scoped
  Continue rules where project-specific behaviour is needed. Stops
  re-teaching every session.
- Scheduled runs via launchd/cron: nightly demo regressions (Step 1
  harness) and repo-health digests via `opencode run`. Glimmer is
  pitched as an always-on agent — let it be one.
- Acceptance: a fresh agent session follows repo conventions without
  prompting; nightly runs land results without manual triggers.

## Step 6 — Later / optional

- IMATRIX-importance quants for quality at the same memory footprint.
- WebUI → Qdrant backend (the stretch goal in `local-intelligence-plan.md` §4).
- Run observability (Langfuse-style traces of prompts/tools/tokens).

## Standing rules

- Every change is scored with the Step 1 harness before adoption.
- Docs follow code: `local-intelligence-plan.md` (same dir), `../continue-config.yaml`,
  `AGENT_MODELS`/provider, and demo READMEs stay in sync (see the
  `add-ollama-model` skill for the model-change checklist).
