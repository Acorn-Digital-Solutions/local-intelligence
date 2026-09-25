---
name: add-ollama-model
description: Add a new model to Ollama and wire it through every consumer (Continue, opencode, docs) with verification at each step.
---

# Add a new model to Ollama

Pulling is only step one: a model is "picked up" when it is verified,
registered in both agent configs, and documented. Work through every step.

## 1. Pre-checks

- `ollama list` — confirm it isn't already there (names must match exactly,
  including tag, e.g. `muse-glimmer:30b-mlx`).
- Size: check the size on the model's `ollama.com/library/<model>` page,
  then `df -h /` for free disk.
- RAM budget: Q4 quant ≈ 0.55–0.6 GB per 1B params; usable ≈ 100 GB of
  128 GB after macOS overhead. Only the *loaded* model uses RAM
  (`ollama ps` shows what's resident) — disk is usually the real limit.
- Tag choice: on Apple Silicon prefer an `-mlx` tag when the library page
  offers one (faster via Ollama's MLX engine); otherwise the default tag.

## 2. Pull and verify install

- `ollama pull <model>[:tag]` (large pulls take a while; partial blobs
  live under `~/.ollama/models/blobs/` until done).
- `ollama list` must now show the model; `ollama show <model>` for details.
- Capabilities (declares what the template supports):
  `curl -s localhost:11434/api/show -d '{"model":"<model>"}'`
  — look for `tools` (agentic candidates), `vision`, `thinking`.
- Chat sanity: `ollama run <model> "Reply with exactly: OK"`.

## 3. Prove tool calling (required before flagging any model agentic)

Narration is failure: a model that prints JSON instead of emitting
`tool_calls` is chat-only (this is how `qwen2.5-coder:32b` and
`deepseek-r1:32b` were disqualified). Prove with one call:

```bash
curl -s localhost:11434/v1/chat/completions -d '{"model":"<model>","messages":[{"role":"user","content":"What is the weather in Paris? Use the tool."}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","required":["city"],"properties":{"city":{"type":"string"}}}}}],"stream":false}' | python3 -c "import json,sys; m=json.load(sys.stdin)['choices'][0]['message']; print('tool_calls:', json.dumps(m.get('tool_calls'))); print('content:', (m.get('content') or '')[:200])"
```

Pass = non-null `tool_calls` with the right name and arguments.

## 4. Wire into Continue (two files)

- Add an entry to the repo template `continue-config.yaml` AND the live
  `~/.continue/config.yaml` (Continue reads only the live one; keep them
  in sync). The `model:` value must match `ollama list` exactly.
- Roles/capabilities: `roles: [chat]` for chat models (+`tool_use` under
  `capabilities:` only if step 3 passed; `image_input` only if `vision`
  was declared; `roles: [embed]` for embedding models).
- Order matters: the first `chat` model is the picker's default — put
  the daily agentic default first.
- Validate both files parse as YAML; Continue reloads the live file on
  save (no restart). Test in a *fresh* session — old sessions keep
  their original model.

## 5. Wire into opencode

- The provider block in `~/.config/opencode/opencode.jsonc` is generated
  by `phase4.sh` from `ollama list`. If step 3 passed, add the model to
  `AGENT_MODELS` in `phase4.sh` (space-separated; first entry is the
  default for one-shot runs and smoke tests).
- Regenerate: re-run `./phase4.sh` (full, idempotent) or just its merge
  step; embedding-only models are skipped automatically
  (`skip_substrings`: `embed`, `bge-m3`, `mxbai`).
- Verify: `opencode models ollama` lists the model; then the smoke test —
  in a scratch dir with `{"permission":{"edit":"allow","bash":"deny"}}`,
  `opencode run --dir <dir> -m ollama/<model> "Create hello.py
  containing exactly print('OK'). Do not run anything."` must create
  the file.

## 6. Update docs

- `local-intelligence-plan.md`: model lists and guidance in sections 2,
  4, 7, 8 as applicable (keep the "proven via :11434/v1" claims true).
- `demo/*/README.md` + `demo/README.md`: update `opencode run -m …`
  flags if the recommended default changed.
- `continue-config.yaml` comments: keep the default/backup notes accurate.
