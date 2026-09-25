---
name: run-setup
description: Execute local-intelligence-setup.sh to build or repair the local AI stack phase by phase (runtimes, models, RAG, chat UI, LAN access).
---

# Run the local-intelligence setup

`local-intelligence-setup.sh` (repo root) is a dispatcher: each `--phaseN`
flag runs the matching `phaseN.sh` script. Always run from the repo root
(`~/local-intelligence`) so `.venv` and relative paths resolve.

## Phase order and dependencies

Run in order on a fresh machine; later phases require earlier ones:

1. `--phase1` — base runtimes: Ollama (brew) + server, LM Studio cask
   check, project `.venv` with `mlx-lm`. No model pulls.
2. `--phase2` — models via Ollama: `qwen2.5-coder:32b`,
   `deepseek-r1:32b`, `llama3.3:70b` (unless `--skip-70b`),
   `nomic-embed-text`. Large (~85GB, ~43GB skipped); disk checked first.
3. `--phase3` — RAG: Qdrant container (pinned image, persistent volume),
   RAG deps into `.venv`, ingest + grounded-retrieve verify. Needs Docker.
4. `--phase4` — Open WebUI container (`:3000`) wired to Ollama for chat
   + embeddings, plus OpenCode provider wiring for local models and an
   agentic smoke test. Needs Docker.
5. `--phase5` — LAN access: binds Ollama to all interfaces (persisted via
   brew services env) so `compute.local:11434`/`:3000` work from other
   machines. Trusted home LAN only — Ollama has no login.

## Procedure

1. Preview first, then run (every phase supports both flags):
   ` ./local-intelligence-setup.sh --phaseN --dry-run`
   `./local-intelligence-setup.sh --phaseN --check-only`
2. Run the phase: `./local-intelligence-setup.sh --phaseN`
   (extra flags are forwarded: `--dry-run --check-only` everywhere,
   plus `--skip-70b` for phase2, `--recreate` for phase3).
3. Multiple phases run left to right:
   `./local-intelligence-setup.sh --phase1 --phase2`
4. Confirm with the plan's manual checks (`plans/local-intelligence-plan.md`
   section 5), e.g. `curl -s localhost:11434/api/version`,
   `ollama list`, `curl -s localhost:6333/collections`.

## Rules

- All phases are idempotent — re-running is safe and is the normal fix
  for a half-finished state. Never hand-edit generated state (Docker
  volumes, brew plist) when re-running the phase fixes it.
- On failure, read the `[phaseN]` log lines, fix the stated cause
  (Docker not running, Ollama down, missing model), re-run the same phase.
- `power-settings.sh` (unattended idle/restart, needs sudo) and
  `benchmark.sh` (MLX vs GGUF shootout) are standalone — not phases.
- Do not run phases in parallel: each assumes the previous one's state.
