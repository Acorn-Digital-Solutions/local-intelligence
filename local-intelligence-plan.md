# Local Intelligence Plan — Mac Pro M4 Ultra / 128GB

Goal: local AI environment to rival big cloud models at a fraction of the cost.
Highly customizable, tailored, no token restrictions. Single Mac Pro M4 Ultra, 128GB unified RAM.

Realistic scope: match cloud for coding, RAG, and custom agents offline. Not frontier 400B+ reasoning.
Usable budget: ~100GB for weights + KV-cache after macOS overhead.

## 1. Runtime layer

Default stack: Ollama + LM Studio. Add llama.cpp / MLX for control / speed.

- **Ollama (default server/CLI)** — native arm64, Metal/GPU by default, OpenAI-compatible `localhost:11434`, GGUF Q2-Q8 via llama.cpp/MLX runners + `ollama create`.
- **LM Studio (GUI + alt server)** — native macOS GUI + `lms` CLI, Metal-accelerated, GGUF + MLX side-by-side, OpenAI server `localhost:1234/v1`, catalog with MLX vs GGUF choice, 4-bit MLX quants.
- **llama.cpp upstream (max control)** — mature Metal backend for unified memory, GGUF Q2_K-Q8 + IQ/IMATRIX, OpenAI-compatible `llama-server`. Underlies Ollama / LM Studio / GPT4All.
- **Apple MLX / mlx-lm (max speed, short/medium context)** — 2-3x prompt-decode vs llama.cpp on M1-M4, up to ~87% faster than Ollama in one test. 4-bit/8-bit, `mlx-community` weights, serve via `mlx-lm server` / `mlx-serve`. Advantage narrows past ~40k context.
- **llamafile v0.10.x (portable)** — single-file macOS arm64 exe, GPU + multimodal in 0.10, bundled OpenAI server. Zero-install pick, smaller selection.
- **GPT4All v3.2-lineage (beginner chat)** — GUI + Python/TS bindings, macOS Metal via llama.cpp, GGUF, local OpenAI-style server. Good offline chat, less flexible dev server.

Avoid on Mac:
- **LocalAI** — Linux/Docker+CUDA-first, Mac CPU/Docker only, no first-class Metal path.
- **vLLM** — no Metal backend, CUDA/Linux production server. `vllm-metal` fork is CPU/hello-world level.

## 2. Models — 128GB sizing

Quant rule: `Q4_K_M` sweet spot. ~0.55-0.6 GB per 1B params.
Q5_K_M / Q6_K / Q8_0 only +1-3 pts for +20-60% memory. Reserve Q8 for <=32B. IQ quants / MLX 4-bit equivalent on Mac.

- 32B Q4 ~20GB
- 70B Q4 ~40-45GB
- 120B Q4 ~65-75GB, fits with large context
- 235B-A22B MoE Q4 ~140GB does NOT fit — use Qwen3-30B-A3B MoE instead

Consensus picks 2025-2026:
- General + coding: Qwen3 / Qwen2.5-Coder-32B, Qwen3-Coder-30B-A3B
- Reasoning: DeepSeek R1/V3 + R1-Distill-Qwen-32B (best step-by-step, slower/verbose)
- Safe fallback: Llama 3.3 70B Q4
- Efficient 20-32B: Gemma 3 27B, Mistral Small 3.1 24B, Phi-4, Devstral 24B
- Tool-call / fill-in-middle: Qwen2.5-Coder-32B, Qwen3-Coder-30B-A3B, Devstral-24B, Mistral Small. StarCoder2 superseded for chat/agentic.
- Context: Qwen3/Qwen2.5-Coder 32k-128k (YaRN), Llama 3.3 128k, Mistral Small 3.1 128k, Gemma 3 128k (sliding-window limits effective), Devstral 128k-256k, R1-distills inherit base 32k-128k. Practical cap is KV-cache RAM, not advertised max.
- Embeddings (tiny, CPU-side): Qwen3-Embedding-0.6B/4B, BGE-M3, Nomic-embed-text-v2, EmbeddingGemma

## 3. App stack — fully local with Ollama

- Frameworks:
  - LangChain 1.3.2 / LangGraph 1.2.2 — agents, tool-calls, checkpointing
  - LlamaIndex 0.14.22 — fastest RAG with Ollama llm+embed packages
  - Haystack 2.29 — typed DAG, YAML-serializable, OTEL/Langfuse
- Vector DBs:
  - Chroma 1.5.9 `PersistentClient` SQLite+HNSW — prototype only (<100k docs, no quantization/sharding, ~57GB/10Mx1536-f32)
  - Qdrant v1.17.1 Rust Docker REST/gRPC — scale pick, native pre-filter + INT8 quantization (~15GB same data, sub-20ms p95)
- Frontend: Open WebUI / LibreChat pointing at Ollama `:11434` or LM Studio `:1234`

## 4. Phased setup

Phase 1 — base:
- Install Ollama + LM Studio
- Serve Qwen3 / Qwen2.5-Coder-32B Q4_K_M (or MLX 4-bit) + embedding model
- Verify via Ollama `:11434` / LM Studio `:1234/v1`

Phase 2 — reasoning fallback:
- Add DeepSeek-R1-Distill-Qwen-32B and Llama 3.3 70B Q4

Phase 3 — RAG stack:
- LlamaIndex or LangChain + Qdrant (scale) or Chroma (prototype) + Qwen3-Embedding / BGE-M3

Phase 4 — chat UI with RAG (the friendly front door):
- Open WebUI `v0.11.3` container, implemented + verified by `phase4.sh`
- Wired to Ollama via `host.docker.internal:11434` for chat AND embeddings
  (`RAG_EMBEDDING_ENGINE=ollama`, `RAG_EMBEDDING_MODEL=nomic-embed-text`;
  env vars apply on a fresh volume — a volume created without them keeps
  sentence-transformers defaults, which also downloads weights from HF)
- Persistent `open-webui-data` volume; reachable at `localhost:3000`
- Knowledge base: upload project docs into a Collection per project, ask
  grounded questions in chat (retrieval happens behind the scenes)
- Stretch: back collections with the Phase 3 Qdrant (`:6333`) so the UI
  and `rag_demo.py` share one index — still open
- Terminal agent: OpenCode (MIT terminal coding agent) driving local models
  - Chosen over Claude Code, which is cloud-only and defeats this setup
  - Install: `brew install opencode`, or the user-local installer
    `curl -fsSL https://opencode.ai/install | bash -s -- --version <stable>`
    (pin the version; the unpinned lookup hits GitHub API rate limits)
  - Status: implemented + verified by `phase4.sh`. Provider definition lives
    in `opencode-ollama-provider.json` next to the script and is merged into
    `~/.config/opencode/opencode.jsonc` under `provider.ollama` (other keys
    never clobbered; schema taken from `https://opencode.ai/config.json`).
    It declares every Ollama chat model (embedding-only excluded);
    `qwen3-coder:30b` auto-pulled (~18GB) as the agentic model. Usage: plan §7.
  - Model caveat, proven live: `qwen2.5-coder:32b` and `deepseek-r1:32b`
    narrate tool calls as text (`tool_calls: null` via `:11434/v1`), so they
    cannot drive the agent loop — chat/generation only. `qwen3-coder:30b`
    emits real structured `tool_calls`.
- Verify: model dropdown lists Phase 2 models, a doc-grounded question
  answers from the uploaded collection (automated probe asserts a
  plan-specific embedding name in the answer), and a non-interactive
  `opencode run` edits a scratch file using only the local model

Phase 5 — optimize, standalone (was Phase 4; NOT part of setup):
- `./benchmark.sh` (own script, own flags): fixed-prompt MLX vs GGUF
  shootout, same model class, tokens/sec + wall time + per-prompt verdict,
  results to timestamped `benchmark-results-*.md`. Not wired into setup.
- Reserve Q8 only for <=32B
- Use Qwen3-30B-A3B MoE if MoE needed
- Cap context by KV RAM

## 5. Manual testing — how to try it

Prerequisite for everything below: the server is running.
`brew services start ollama` (persists across logins), then
`curl -s localhost:11434/api/version` should print a version.
Scripts also self-check: `./phase1.sh --check-only`, `./phase2.sh --check-only`.

Phase 1 — runtimes:
- `ollama --version` → client version; compare with server version above
- `command -v lms && lms --version` → LM Studio CLI resolving via PATH
- `source .venv/bin/activate && python -c "import mlx_lm; print('mlx ok')"`
- Try it: `ollama run qwen2.5-coder:32b "Reply with exactly: OK"`
  (needs a Phase 2 model; `q` / `/bye` to exit the chat)

Phase 2 — models:
- `ollama list` → expect `qwen2.5-coder:32b`, `deepseek-r1:32b`,
  `nomic-embed-text` (plus `llama3.3:70b` unless pulled with `--skip-70b`)
- `ollama show qwen2.5-coder:32b` → model details, no download
- Try coding: `ollama run qwen2.5-coder:32b "write quicksort in python"`
- Try reasoning: `ollama run deepseek-r1:32b "why is the sky blue? be brief"`
  (verbose step-by-step is normal for R1-distills)
- Try embeddings (expect `"embeddings":[[...]]`):
  `curl -s localhost:11434/api/embed -d '{"model":"nomic-embed-text","input":"hello world"}'`
- Try OpenAI-compatible API: `curl -s localhost:11434/v1/models`
  and `curl -s localhost:11434/v1/chat/completions`
  `-d '{"model":"qwen2.5-coder:32b","messages":[{"role":"user","content":"say OK"}]}'`
- `ollama ps` → what's loaded now (size, GPU, context, keep-alive)

Phase 3 — RAG (`./phase3.sh`: Qdrant v1.17.1 + `local-intel` collection):
- `curl -s localhost:6333/collections` → Qdrant up with your collection
- Try it: `.venv/bin/python rag_demo.py --query "Which embedding models does the plan recommend?"`
  → scored hits citing `local-intelligence-plan.md`
- Re-ingest after editing docs: `./phase3.sh --recreate`
  (demo corpus is the project `*.md` files themselves)

## 6. Using RAG on a new coding project

The idea in one paragraph: your files are split into chunks, each chunk is
embedded locally (`nomic-embed-text` via Ollama) and stored in Qdrant with
its source path. At ask time the question is embedded the same way, Qdrant
returns the most similar chunks, and those chunks go into the model's prompt
as context. No data leaves the machine at any step.

Walkthrough (example project at `~/code/myproj`, all commands from this repo
dir so `.venv` resolves; one collection per project):

1. Services up: `brew services start ollama` (persists across logins),
   `docker start qdrant`. `./phase3.sh --check-only` confirms both plus
   the embedding model.
2. Ingest the code:
   `.venv/bin/python rag_demo.py --corpus ~/code/myproj --pattern '**/*.py' --pattern '**/*.md' --collection myproj --ingest`
   Junk (`.git`, `node_modules`, `__pycache__`, `.venv`, `dist`, `build`,
   lockfiles, binaries) is skipped automatically. Re-runs upsert in place,
   so re-ingest after edits is safe; add `--recreate` for a full rebuild.
3. Ask:
   `.venv/bin/python rag_demo.py --collection myproj --query "where is auth handled?"`
   → top chunks with scores and source paths.
4. Answer with the model, two options:
   a. Manual: `ollama run qwen2.5-coder:32b`, paste the retrieved chunks
      as context, then ask.
   b. Scriptable: take step 3's chunks and call
      `curl localhost:11434/api/generate -d '{"model":"qwen2.5-coder:32b","prompt":"Context:\n<chunks>\n\nQuestion: ...","stream":false}'`
5. Housekeeping: `curl -s localhost:6333/collections` lists collections
   (one per project keeps codebases from polluting each other).

Tuning notes: code likes bigger chunks than prose (the 512/50 default is a
fine start); `deepseek-r1:32b` reasons better over retrieved context but is
verbose — coder first, reasoning when stuck.

## 7. Using OpenCode with local models

`phase4.sh` registers every Ollama chat model as an `ollama/*` provider
(`~/.config/opencode/opencode.jsonc`, merged never clobbered; embedding-only
models excluded — they can't chat). Your global default model is untouched:
local models are always chosen explicitly, so nothing reaches the cloud.

- Interactive: `cd ~/code/myproj && opencode` → TUI, pick an `ollama/*`
  model in the picker, approve each edit as it asks.
- One-shot: `opencode run -m ollama/qwen3-coder:30b "add retry logic to fetch.py"`
  (`--dir` to target another directory without cd-ing).
- Which model: `qwen3-coder:30b` for agentic edits (the only local model
  proven to invoke tools); `qwen2.5-coder:32b` for coding Q&A in chat;
  `deepseek-r1:32b` for step-by-step reasoning (verbose, no tool use).
- Permissions: edits/shell prompt by default; `--auto` approves everything
  (dangerous — avoid). For unattended runs, a project-local `opencode.json`
  pre-allows scoped rights, e.g. `{"permission":{"edit":"allow","bash":"deny"}}`.
- Machine-readable runs: append `--format json` (one event per line).
- Check the wiring anytime: `opencode models ollama`.

Phase 4 — chat UI with RAG (provisional; applies once `phase4.sh` lands):
- Open `localhost:3000`, sign in, model dropdown lists Phase 2 models
- Try it: Workspace → Knowledge → new Collection → upload this plan file,
  then chat "which embedding model does the plan use?" → grounded answer
- `docker ps` shows `open-webui` healthy; data survives `docker restart open-webui`
- Terminal agent: `opencode run -m ollama/qwen3-coder:30b "<task>"` in a
  scratch dir — file gets edited with no cloud traffic (config + smoke test
  in `phase4.sh`; project-local `opencode.json` can pre-allow edits)

Phase 5 — optimize (`./benchmark.sh`, standalone):
- Try it: `./benchmark.sh --quick` (1 prompt, 64 tokens) then full `./benchmark.sh`
- Results land in `benchmark-results-<date>.md` with per-prompt winners
- Contenders via env: `OLLAMA_MODEL=... MLX_MODEL=... ./benchmark.sh`
- Context sizing: `ollama ps` CONTEXT column vs the model's trained
  context (`ollama show <model>`); if answers degrade past some length,
  the KV-cache (not the advertised max) is the practical cap
