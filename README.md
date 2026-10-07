# local-intelligence

Local AI environment on a Mac Pro M4 Ultra (128GB): Ollama-served open
models driving terminal agents (opencode), VS Code agents (Continue),
and a chat UI (Open WebUI). Agents read code directly — no vector-DB
layer. No cloud traffic.

## Get started

Prerequisites: macOS Apple Silicon, Homebrew, Docker Desktop (phase 4),
git. All commands run from the repo root.

```bash
./local-intelligence-setup.sh --phase1 --phase2   # runtimes + models (large downloads)
./local-intelligence-setup.sh --phase4            # chat UI + opencode wiring
curl -s localhost:11434/api/version               # Ollama up?
ollama list                                       # models present?
opencode run -m ollama/muse-glimmer:30b-mlx "Reply with exactly: OK"
```

Then open http://localhost:3000 (chat UI) and `demo/` (agent demos).
Every phase supports `--dry-run` and `--check-only`; all phases are
idempotent — re-running is the normal fix for a half-finished state.
Full design rationale lives in `plans/`.

## Repository layout

| Path | Purpose |
|---|---|
| `plans/` | Design docs: `local-intelligence-plan.md` (architecture, sizing, usage), `follow-up-plan1.md` (agent roadmap) |
| `local-intelligence-setup.sh` | Phase dispatcher (`--phase1`, `--phase2`, `--phase4`, `--phase5`; phase 3 retired) |
| `phase1.sh`, `phase2.sh`, `phase4.sh`, `phase5.sh` | Runtimes, models, chat UI + opencode, LAN access |
| `power-settings.sh` | Unattended Mac (sudo): no idle sleep, auto-restart |
| `continue-config.yaml` | Continue template → copy to `~/.continue/config.yaml` |
| `configs/` | Script-read configs: opencode provider (server), opencode client defaults, eval permissions, Continue client template |
| `agent_tools_mcp.py` + `agent-tools-mcp.launchd.plist` | Server-hosted web search/fetch + sequential-thinking tools over MCP |
| `demo/` | Three agent demos (code, live web, long text) + graders |
| `eval.sh` | Model × demo eval matrix (outputs gitignored) |
| `benchmark.sh` | MLX vs GGUF speed shootout (standalone) |
| `skills/` | Agent skills (`run-setup`, `add-ollama-model`) for Continue `read_skill` |
| `cleanup.sh` | Tear down containers/volumes |
| `client-setup.sh` | Self-contained client setup (Continue + opencode → this server; needs VS Code pre-installed) |
| `.vscode/settings.json` | Applies automatically when this folder is open (uses `.venv`) |

## Setup in detail

`./local-intelligence-setup.sh --phaseN` runs `phaseN.sh`:

1. **Runtimes** — Ollama (brew) + server, LM Studio check, `.venv` with `mlx-lm`.
2. **Models** — coder + reasoning + 70B fallback + embeddings
   (`--skip-70b` saves ~40GB). Agentic models (Glimmer, GPT-OSS, Qwen3)
   are pulled by phase 4 / on demand — see the `add-ollama-model` skill.
3. **RAG (retired)** — the Qdrant + RAG-MCP layer was removed; agents
   navigate code with grep/glob/read at 131K context instead.
4. **Chat UI + agent** — Open WebUI on `:3000`, opencode provider + MCP
  endpoint, agentic smoke test. Start the agent-tools MCP service separately; see plan §9.
5. **LAN access** — binds Ollama to all interfaces (`compute.local`).
   Trusted home LAN only: Ollama has no login.

## Daily use

**Terminal agent (opencode):**

```bash
cd ~/code/myproj && opencode                                   # interactive TUI
opencode run -m ollama/muse-glimmer:30b-mlx "add retry logic"  # one-shot
opencode run -m ollama/gpt-oss:120b "..."                      # harder tasks
opencode models ollama                                         # check wiring
```

Model guide: Glimmer for agentic edits (fast, MLX), GPT-OSS 120B when
quality beats speed, Qwen3 backup, Qwen2.5-Coder for plain chat Q&A
(no tools — it narrates tool calls as text instead of invoking them,
so switch to Glimmer for anything needing web, MCP, or file tools),
DeepSeek-R1 for step-by-step reasoning. Pre-allow permissions per
project with a local `opencode.json`
(`{"permission":{"edit":"allow","bash":"deny"}}`); never `--auto`.

**VS Code (Continue):** install the Continue extension, open this folder,
`cp continue-config.yaml ~/.continue/config.yaml`. Switch the input-bar
mode toggle to **Agent** — MCP tools (web search/fetch, thinking) don't
exist in Chat mode, and models asked to use tools there just narrate fake calls
as text. Agent mode needs the `Muse Glimmer 30B (agentic)` picker entry —
Qwen2.5 narrates tool calls as text and can't drive tools. `Cmd+Enter`
accepts each approval prompt (approvals are per-call by design). See plan
§8 + Agent-mode notes.

**Chat UI:** http://localhost:3000 — upload docs into a Knowledge
collection, ask grounded questions.

**Searching your own project:** agents navigate code with grep/glob/read
directly (see the explore subagent in `configs/`), Continue's `@codebase`
covers indexed search, and the chat UI's Knowledge collections cover
doc Q&A. No ingest step — just point the agent at the directory.

## Demos, evals, skills

- `demo/`: `01-coding-bob` (code+test loop), `02-internet-research`
  (live web, needs internet), `03-text-alice` (long-context read over
  a 151KB book, no extra services). Each README has the agent command + grader.
- `./eval.sh`: runs every demo × every agentic model, grades with the
  demo checkers, writes a pass/fail matrix (`EVAL_MODELS`,
  `EVAL_DEMOS`, `EVAL_TIMEOUT` narrow the run). Results and raw logs
  are gitignored by design.
- `skills/`: `run-setup` (this setup) and `add-ollama-model` (full
  new-model checklist: pull, tool-call proof, Continue + opencode
  wiring, docs). Continue agents load them via `read_skill`.

## Troubleshooting

- `curl: connection refused` on `:11434` → `brew services start ollama`.
- Docker errors in phase 4 → open Docker Desktop, re-run the phase.
- Continue can't reach models → same server checks; model names must
  match `ollama list` exactly; use a fresh session after config edits.
- Red crossed-out "Agent tool use" in Continue → failed tool call
  (wrong name/args); the config's `rules:` block pins the exact schemas.
- `opencode models ollama` missing models → re-run `./phase4.sh`.
