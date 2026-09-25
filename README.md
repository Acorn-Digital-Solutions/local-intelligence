# local-intelligence

Local AI environment on a Mac Pro M4 Ultra (128GB): Ollama-served open
models driving terminal agents (opencode), VS Code agents (Continue),
a chat UI (Open WebUI), and a Qdrant RAG stack. No cloud traffic.

## Get started

Prerequisites: macOS Apple Silicon, Homebrew, Docker Desktop (phases 3–4),
git. All commands run from the repo root.

```bash
./local-intelligence-setup.sh --phase1 --phase2   # runtimes + models (large downloads)
./local-intelligence-setup.sh --phase3 --phase4   # RAG + chat UI + opencode wiring
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
| `local-intelligence-setup.sh` | Phase dispatcher (`--phase1`…`--phase5`) |
| `phase1.sh`…`phase5.sh` | Runtimes, models, RAG, chat UI + opencode, LAN access |
| `power-settings.sh` | Unattended Mac (sudo): no idle sleep, auto-restart |
| `continue-config.yaml` | Continue template → copy to `~/.continue/config.yaml` |
| `opencode-ollama-provider.json` | opencode provider template (merged by `phase4.sh`) |
| `rag_demo.py` | Qdrant ingest + query CLI for project RAG |
| `demo/` | Three agent demos (code, live web, long text) + graders |
| `eval.sh` | Model × demo eval matrix (outputs gitignored) |
| `benchmark.sh` | MLX vs GGUF speed shootout (standalone) |
| `skills/` | Agent skills (`run-setup`, `add-ollama-model`) for Continue `read_skill` |
| `cleanup.sh` | Tear down containers/volumes |
| `client-setup.sh` | Self-contained client setup (Continue + opencode → this server; needs VS Code pre-installed) |
| `rag_mcp.py` + `rag-mcp.launchd.plist` | RAG over MCP (stdio local, HTTP for clients) |
| `.vscode/settings.json` | Applies automatically when this folder is open (uses `.venv`) |

## Setup in detail

`./local-intelligence-setup.sh --phaseN` runs `phaseN.sh`:

1. **Runtimes** — Ollama (brew) + server, LM Studio check, `.venv` with `mlx-lm`.
2. **Models** — coder + reasoning + 70B fallback + embeddings
   (`--skip-70b` saves ~40GB). Agentic models (Glimmer, GPT-OSS, Qwen3)
   are pulled by phase 4 / on demand — see the `add-ollama-model` skill.
3. **RAG** — Qdrant container + deps + ingest/verify (`--recreate` rebuilds).
4. **Chat UI + agent** — Open WebUI on `:3000`, opencode provider merge,
   agentic smoke test.
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
quality beats speed, Qwen3 backup, Qwen2.5-Coder for chat Q&A,
DeepSeek-R1 for step-by-step reasoning. Pre-allow permissions per
project with a local `opencode.json`
(`{"permission":{"edit":"allow","bash":"deny"}}`); never `--auto`.

**VS Code (Continue):** install the Continue extension, open this folder,
`cp continue-config.yaml ~/.continue/config.yaml`. Agent mode needs the
`Muse Glimmer 30B (agentic)` picker entry — Qwen2.5 narrates tool calls
as text and can't drive tools. `Cmd+Enter` accepts each approval prompt
(approvals are per-call by design). See plan §8 + Agent-mode notes.

**Chat UI:** http://localhost:3000 — upload docs into a Knowledge
collection, ask grounded questions.

**RAG on your own project** (one collection per project):

```bash
.venv/bin/python rag_demo.py --corpus ~/code/myproj --pattern '**/*.py' \
  --pattern '**/*.md' --collection myproj --ingest
.venv/bin/python rag_demo.py --collection myproj --query "where is auth handled?"
```

## Demos, evals, skills

- `demo/`: `01-coding-bob` (code+test loop), `02-internet-research`
  (live web, needs internet), `03-text-alice` (RAG over 151KB book,
  needs Qdrant). Each README has the agent command + grader.
- `./eval.sh`: runs every demo × every agentic model, grades with the
  demo checkers, writes a pass/fail matrix (`EVAL_MODELS`,
  `EVAL_DEMOS`, `EVAL_TIMEOUT` narrow the run). Results and raw logs
  are gitignored by design.
- `skills/`: `run-setup` (this setup) and `add-ollama-model` (full
  new-model checklist: pull, tool-call proof, Continue + opencode
  wiring, docs). Continue agents load them via `read_skill`.

## Troubleshooting

- `curl: connection refused` on `:11434` → `brew services start ollama`.
- Docker errors in phases 3–4 → open Docker Desktop, re-run the phase.
- Continue can't reach models → same server checks; model names must
  match `ollama list` exactly; use a fresh session after config edits.
- Red crossed-out "Agent tool use" in Continue → failed tool call
  (wrong name/args); the config's `rules:` block pins the exact schemas.
- `opencode models ollama` missing models → re-run `./phase4.sh`.
