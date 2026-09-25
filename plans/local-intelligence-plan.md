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
- Agentic default: Muse Glimmer 30B (`muse-glimmer:30b-mlx` via Ollama's
  MLX engine, 128K, vision+tools+thinking) — purpose-built for tool use
  and failure recovery. Heavyweight: `gpt-oss:120b` (~65GB) for the
  hardest reasoning/agentic work; both fit 128GB with KV headroom
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
    every `AGENT_MODELS` entry auto-pulled and flagged `tool_call`
    (`muse-glimmer:30b-mlx`, `gpt-oss:120b`, `qwen3-coder:30b`).
    Usage: plan §7.
  - Model caveat, proven live: `qwen2.5-coder:32b` and `deepseek-r1:32b`
    narrate tool calls as text (`tool_calls: null` via `:11434/v1`), so they
    cannot drive the agent loop — chat/generation only. `qwen3-coder:30b`,
    `muse-glimmer:30b-mlx` and `gpt-oss:120b` emit real structured
    `tool_calls` with correct argument schemas.
- Verify: model dropdown lists Phase 2 models, a doc-grounded question
  answers from the uploaded collection (automated probe asserts a
  plan-specific embedding name in the answer), and a non-interactive
  `opencode run` edits a scratch file using only the local model

Phase 5 — LAN access (`phase5.sh`):
- Binds Ollama to all interfaces (`OLLAMA_HOST=0.0.0.0`, persisted in the
  brew services plist; ships localhost-only, WebUI already publishes `:3000`)
- Machine name `compute` (`compute.local` via Bonjour/mDNS — tracks DHCP IP
  changes, no DNS server needed). Set once:
  `scutil --set ComputerName/LocalHostName/HostName`
- Verify: `http://compute.local:11434` + `:3000` reachable from other LAN machines
- From elsewhere: Ollama API at `compute.local:11434` (`/v1` for
  OpenAI-compat, e.g. opencode provider `baseURL`), WebUI login at
  `compute.local:3000` (fall back to the DHCP IP if a client lacks mDNS)
- SECURITY: Ollama has no login — anyone on the LAN can use AND administer
  models. Trusted home LAN only; allow Ollama/Docker in the macOS firewall
  prompt when it appears.
- Unattended (`power-settings.sh`, run with sudo): `sleep 0` so services
  survive idle, `displaysleep 10` + `disksleep 10` so idle stays cheap,
  `autorestart 1` to recover from power cuts. Pair with a screen lock
  (System Settings > Lock Screen) and Docker Desktop > Start at login.

Standalone (not a phase): `./benchmark.sh` — fixed-prompt MLX vs GGUF
shootout with per-prompt verdicts. Also: reserve Q8 for <=32B, Qwen3-30B-A3B
MoE if a fast generalist is needed, cap context by KV RAM.

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
- One-shot: `opencode run -m ollama/muse-glimmer:30b-mlx "add retry logic to fetch.py"`
  (`--dir` to target another directory without cd-ing).
- Which model: `muse-glimmer:30b-mlx` for agentic edits (fast, agent-tuned,
  MLX-accelerated); `gpt-oss:120b` when reasoning quality matters more
  than speed; `qwen3-coder:30b` as backup (all three proven to invoke
  tools); `qwen2.5-coder:32b` for coding Q&A in chat; `deepseek-r1:32b`
  for step-by-step reasoning (verbose, no tool use).
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
- Terminal agent: `opencode run -m ollama/muse-glimmer:30b-mlx "<task>"` in a
  scratch dir — file gets edited with no cloud traffic (config + smoke test
  in `phase4.sh`; project-local `opencode.json` can pre-allow edits)

Phase 5 — LAN access:
- Try it: from another machine on the same Wi-Fi, open `http://compute.local:3000`
- API check: `curl http://compute.local:11434/api/version`
- Fallback if a client can't do mDNS: use the DHCP IP (`ipconfig getifaddr en0`)

Standalone benchmark (`./benchmark.sh`, not a phase):
- Try it: `./benchmark.sh --quick` (1 prompt, 64 tokens) then full `./benchmark.sh`
- Results land in `benchmark-results-<date>.md` with per-prompt winners
- Contenders via env: `OLLAMA_MODEL=... MLX_MODEL=... ./benchmark.sh`
- Context sizing: `ollama ps` CONTEXT column vs the model's trained
  context (`ollama show <model>`); if answers degrade past some length,
  the KV-cache (not the advertised max) is the practical cap

## 8. Using local models in VSCode (Continue)

Two files, two homes — this split is forced by the tools, not a choice:
`.vscode/settings.json` is read automatically by VS Code per open folder
(Python interpreter + terminal env), while Continue reads its models only
from `~/.continue/config.yaml` and ignores `settings.json` for them. The
repo template is `continue-config.yaml` at the repo root.

Path A — on this Mac, working in this repo
(prerequisite: `brew services start ollama`):

1. Install the assistant: in VS Code, Extensions view (`Cmd+Shift+X`) →
   search "Continue" → Install (publisher Continue, id
   `Continue.continue`). The Continue logo appears in the sidebar.
2. Open this repo as the workspace: File → Open Folder →
   `~/local-intelligence`. `.vscode/settings.json` applies by itself —
   nothing to import. Why it exists: without it VS Code runs Python with
   the system interpreter and `rag_demo.py` fails on missing deps; with
   it, Run/Debug uses the project `.venv`. Confirm: status bar shows
   `.venv`, and a new integrated terminal (`Ctrl+`` `) has the venv
   activated (`which python` → `.venv/bin/python`).
3. Install the model config (one copy, user-wide — it then serves every
   project, not just this repo):
   `mkdir -p ~/.continue && cp continue-config.yaml ~/.continue/config.yaml`
   Continue reloads it on save, no restart needed. If Continue already
   created a `config.yaml`, merge the `models:` block instead of
   overwriting. Model names must match `ollama list` exactly.
4. Use it: `Cmd+L` chat (model switcher: `Muse Glimmer 30B` for Agent
   mode with tools, `GPT-OSS 120B` for heavyweight agentic work,
   `Qwen2.5-Coder 32B` for coding Q&A, `DeepSeek R1 32B` for
   step-by-step reasoning), `Cmd+I` inline edit, `@codebase` to ask
   over the indexed workspace (embedded locally by `nomic-embed-text`,
   the same model as the Phase 3 RAG stack). Indexing runs on first use.

Path B — from another computer on the LAN, no repo needed
(prerequisites: Phase 5 done so Ollama is LAN-bound, server running):

1. Install Continue in that machine's VS Code (same as step A1).
2. Copy the model config there with one change: every `apiBase` becomes
   `http://compute.local:11434` instead of `http://127.0.0.1:11434`
   (fall back to the Mac's DHCP IP, e.g. `http://192.168.0.101:11434`,
   if the client lacks mDNS). Save as `~/.continue/config.yaml`
   (macOS/Linux) or `%USERPROFILE%\.continue\config.yaml` (Windows).
   The repo's `.vscode/settings.json` is irrelevant here — it only
   matters when this folder itself is open.
3. Same usage as step A4. The first chat wakes/loads the model on the
   Mac, so expect a slower first answer; `ollama ps` on the Mac shows it.

Optional tab autocomplete (both paths): needs a small model the phases
don't install — on the Mac, `ollama pull qwen2.5-coder:1.5b`, then
uncomment the autocomplete block at the bottom of the active
`config.yaml` (adjusting `apiBase` for path B). The installed 30B+
models are seconds per suggestion — unusable here.

Verify: with Ollama up, Continue chat answers using the selected local
model. If Continue reports a connection error, re-check the server from
the client machine first (`curl http://compute.local:11434/api/version`
for path B, `curl -s 127.0.0.1:11434/api/version` on the Mac) — Continue
can't reach a stopped server. No account, no API key, no cloud traffic
on either path; path B inherits the Phase 5 caveat (trusted LAN only —
Ollama has no login).

Agent-mode notes (verified live against Continue 2.0.0):
- Model: use `Muse Glimmer 30B (agentic)` for the whole session (it's
  the picker default — first `chat` model in `config.yaml`),
  `GPT-OSS 120B` for harder tasks, `Qwen3-Coder 30B` as backup.
  Qwen2.5-Coder narrates tool calls as plain-text JSON and never
  executes them.
- The config's `rules:` block pins exact tool names/arguments
  (`read_file(filepath)`, `run_terminal_command(command)`, …) because
  Qwen3-30B otherwise invents near-misses (`file_read`, `filePath`)
  that fail with "Tool … not found". A red crossed-out "Agent tool use"
  entry means a tool call failed this way — check the name/args.
- Approval is per call: writes and terminal commands always prompt
  (no session-wide accept exists in 2.0.0); `Cmd+Enter` accepts each
  prompt. Reads (`read_file`, glob, grep, `ls`) run without prompts.
- Reliability: `@`-mention files (`@demo/01-coding-bob/bob_test.py`)
  instead of relying on the read tool; start a fresh session after
  config changes (old sessions keep their original model). For
  unattended runs prefer opencode (§7) over Continue Agent.

## 9. Client machines + RAG MCP service

This Mac is the server; daily work happens on client machines on the same
LAN. Two halves, both required for retrieval on clients:

Server side — persistent RAG MCP service (`rag_mcp.py`, stdio for local
use + `streamable-http` for clients, tools: `rag_query`, `rag_ingest`,
`rag_collections`):

1. The installed copy lives at
   `~/Library/LaunchAgents/org.local-intel.rag-mcp.plist`, generated
   from the repo template `rag-mcp.launchd.plist` (`__ROOT__` replaced
   with the checkout path). Serve binds `0.0.0.0:8011`.
2. Load/unload from your own Terminal (agent shells can't bootstrap):
   `launchctl load -w ~/Library/LaunchAgents/org.local-intel.rag-mcp.plist`
   (modern form `launchctl bootstrap gui/$(id -u) <same file>` fails with
   error 5 on this machine; unload: `launchctl unload <same file>`).
3. Verify: `curl -s -o /dev/null -w "%{http_code}\n"
   http://127.0.0.1:8011/mcp` → `400` (means alive: the endpoint wants
   POST). Logs: `/tmp/rag-mcp.log`. `RunAtLoad` + `KeepAlive` keep it
   up across logins and crashes.
4. SECURITY: no auth — trusted LAN only, same posture as the Phase 5
   Ollama bind. Never port-forward `:8011` to the internet.

Client side — one script does it all (`client-setup.sh`, self-contained,
macOS with Homebrew or apt/dnf Linux; Windows via WSL2):

1. Copy it over: `scp client-setup.sh user@client:~/`
2. On the client: `bash ~/client-setup.sh` (`--server HOST` to override
   the default `compute.local`, e.g. the server's LAN IP if mDNS fails;
   `--dry-run` / `--check-only` supported).
3. It installs the Continue extension (needs VS Code with `code` on
   PATH already — not installed by the script), writes
   `~/.continue/config.yaml` (server models, tool-pin rules, remote
   `rag` MCP entry), installs opencode, and merges `provider.ollama`
   (models enumerated live from the server) + `mcp.rag` into
   `~/.config/opencode/opencode.jsonc`, setting the default model to
   Qwen3-Coder 30B (best coding model with proven tool-calling; small
   model: 1.5B coder). Existing configs are backed up,
   never clobbered. LAN hosts bypass any proxy env. It finishes with a
   live retrieval verification (MCP probe + Continue checks).
4. Verify on the client: `opencode models ollama` lists server models;
   new Continue Agent session defaults to Glimmer.

Troubleshooting: server checks first from the client
(`curl http://compute.local:11434/api/tags`,
`curl http://compute.local:8011/mcp` → 400); Continue MCP tools appear
only when the server-side service (§9, server half) is running.
