#!/usr/bin/env bash
# phase4.sh — Phase 4 chat UI with RAG for plans/local-intelligence-plan.md
# Runs Open WebUI (pinned image) wired to Ollama for chat + embeddings,
# creates the admin user, and verifies a grounded RAG answer end to end.
# Also ensures the OpenCode terminal agent binary (provider wiring for the
# local models is finished once the binary is present — see ensure_opencode).
# Idempotent — safe to re-run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$ROOT_DIR/.venv/bin/python"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.11.3"
WEBUI_NAME="open-webui"
WEBUI_URL="http://127.0.0.1:3000"
OLLAMA_URL="http://127.0.0.1:11434"
OLLAMA_DOCKER_URL="http://host.docker.internal:11434"
CHAT_MODEL="qwen2.5-coder:32b"
EMBED_MODEL="nomic-embed-text"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD="${OPENWEBUI_ADMIN_PASSWORD:-local-admin-changeme}"

DRY_RUN=0
CHECK_ONLY=0

log() { printf '[phase4] %s\n' "$*"; }
warn() { printf '[phase4] WARN: %s\n' "$*" >&2; }
die() { printf '[phase4] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./phase4.sh [options]

Phase 4: Open WebUI chat UI (RAG-incorporated) + OpenCode terminal agent.

Options:
  --dry-run    Show what would change, do nothing
  --check-only Verify current state, change nothing
  -h, --help   Show this help

Env:
  OPENWEBUI_ADMIN_PASSWORD  Admin password (default is weak: change it in the UI)

Try it: open http://localhost:3000 — Knowledge collection + chat,
  or `opencode run "<task>"` once the binary is installed.
EOF
}

webui_up() {
  curl -sf --max-time 3 "$WEBUI_URL/health" >/dev/null 2>&1
}

preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Desktop for Mac, then re-run."
  docker info >/dev/null 2>&1 || die "docker daemon not running — open Docker Desktop, then re-run."
  [[ -x "$VENV_PY" ]] || die "project .venv missing — run ./phase1.sh first."
  curl -sf --max-time 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 \
    || die "ollama server not reachable — run ./phase1.sh first."
  ollama show "$CHAT_MODEL" >/dev/null 2>&1 \
    || die "chat model $CHAT_MODEL missing — run ./phase2.sh first."
  ollama show "$EMBED_MODEL" >/dev/null 2>&1 \
    || die "embedding model $EMBED_MODEL missing — run ./phase2.sh first."
  log "preflight OK (docker, .venv, ollama+$CHAT_MODEL+$EMBED_MODEL)."
}

ensure_webui() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$WEBUI_NAME"; then
    log "open-webui container running."
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$WEBUI_NAME"; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "open-webui STOPPED (check-only; would start it)."; return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then log "[dry-run] would run: docker start $WEBUI_NAME"; return 0; fi
    log "Starting stopped open-webui container..."
    docker start "$WEBUI_NAME" >/dev/null
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "open-webui MISSING (check-only; would run $WEBUI_IMAGE)."; return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: docker run -d $WEBUI_IMAGE (:3000, volume open-webui-data)"
      return 0
    fi
    log "Pulling $WEBUI_IMAGE..."
    docker pull "$WEBUI_IMAGE"
    log "Creating open-webui (Ollama chat + Ollama RAG embeddings)..."
    docker run -d --name "$WEBUI_NAME" --restart unless-stopped \
      -p 3000:8080 \
      -v open-webui-data:/app/backend/data \
      -e "OLLAMA_BASE_URL=$OLLAMA_DOCKER_URL" \
      -e RAG_EMBEDDING_ENGINE=ollama \
      -e "RAG_EMBEDDING_MODEL=$EMBED_MODEL" \
      -e "RAG_OLLAMA_BASE_URL=$OLLAMA_DOCKER_URL" \
      "$WEBUI_IMAGE" >/dev/null
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would wait for $WEBUI_URL/health"
    return 0
  fi
  local i
  for i in $(seq 1 60); do
    if webui_up; then log "open-webui reachable (:3000)."; return 0; fi
    sleep 2
  done
  warn "open-webui not answering on :3000 — see: docker logs $WEBUI_NAME"
  return 1
}

# Prints a Bearer token for the admin user (signup on first run, signin after).
webui_token() {
  local resp token
  resp="$(curl -s --max-time 15 -X POST "$WEBUI_URL/api/v1/auths/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"admin\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"
  token="$(echo "$resp" | "$VENV_PY" -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)"
  if [[ -z "$token" ]]; then
    resp="$(curl -s --max-time 15 -X POST "$WEBUI_URL/api/v1/auths/signin" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"
    token="$(echo "$resp" | "$VENV_PY" -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)"
  fi
  if [[ -z "$token" ]]; then
    warn "admin auth failed — wrong OPENWEBUI_ADMIN_PASSWORD for existing account?"
    return 1
  fi
  echo "$token"
}

OPENCODE_CFG="$HOME/.config/opencode/opencode.jsonc"
# Agentic-capable local models (tool_calls proven via :11434/v1; the 32B
# chat/coder + r1-distill narrate tool calls as text instead of invoking
# them). First entry is the default for one-shot runs and smoke tests.
AGENT_MODELS="muse-glimmer:30b-mlx gpt-oss:120b qwen3-coder:30b"
AGENT_MODEL="$(echo "$AGENT_MODELS" | awk '{print $1}')"

ensure_opencode() {
  if ! command -v opencode >/dev/null 2>&1; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "opencode MISSING (check-only; would try: brew install opencode)."
      return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: brew install opencode (fallback: opencode.ai/install --version <stable>)"
      return 0
    fi
    if command -v brew >/dev/null 2>&1 && brew install opencode; then
      log "opencode installed via brew."
    else
      warn "opencode NOT installed (brew failed in this shell) — run in your own Terminal:"
      warn "  brew install opencode   # or: curl -fsSL https://opencode.ai/install | bash -s -- --version <stable>"
      return 1
    fi
  fi
  log "opencode present: $(opencode --version 2>/dev/null || echo unknown)"
  local m
  for m in $AGENT_MODELS; do
    if ollama show "$m" >/dev/null 2>&1; then continue; fi
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "agentic model $m MISSING (check-only; would pull it)."
      return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: ollama pull $m"
      return 0
    fi
    log "Pulling agentic model $m..."
    ollama pull "$m" || { warn "FAILED to pull $m."; return 1; }
  done
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    log "check-only: skipping config write."
    command -v opencode >/dev/null 2>&1 && opencode models ollama 2>/dev/null | grep -q "$AGENT_MODEL" \
      && log "ollama provider configured." || warn "ollama provider NOT configured (would write it)."
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would merge opencode-ollama-provider.json into $OPENCODE_CFG"
    return 0
  fi
  # Merge (never clobber): provider definition comes from the sidecar file
  # opencode-ollama-provider.json; the models block is built from
  # `ollama list` so the picker shows every chat model. Embedding-only
  # models can't chat and are skipped; every proven agentic model is
  # flagged tool_call (the 32Bs narrate calls as text).
  local template="$ROOT_DIR/opencode-ollama-provider.json"
  [[ -f "$template" ]] || { warn "provider template missing: $template"; return 1; }
  AGENT_MODELS="$AGENT_MODELS" OPENCODE_CFG="$OPENCODE_CFG" \
    PROVIDER_TEMPLATE="$template" "$VENV_PY" - <<'EOF'
import json, os, subprocess
p = os.environ["OPENCODE_CFG"]
agents = set(os.environ["AGENT_MODELS"].split())
tpl = json.load(open(os.environ["PROVIDER_TEMPLATE"]))
out = subprocess.run(["ollama", "list"], capture_output=True, text=True)
names = [l.split()[0] for l in out.stdout.splitlines()[1:] if l.split()]
models = {}
for m in names:
    if any(s in m for s in tpl.get("skip_substrings", [])):
        print(f"skipping embedding-only model: {m}")
        continue
    agentic = (m in agents)
    models[m] = {
        "name": m + (tpl["agentic_name_suffix"] if agentic else tpl["model_name_suffix"]),
        "tool_call": agentic,
        "limit": tpl["default_limit"],
    }
if not models:
    raise SystemExit("no chat models in ollama list")
try:
    d = json.load(open(p))
except (FileNotFoundError, ValueError) as e:
    raise SystemExit(f"refusing to touch {p} (missing or not plain JSON): {e}")
provs = d.setdefault("provider", {})
provs["ollama"] = {
    "npm": tpl["npm"],
    "name": tpl["name"],
    "options": tpl["options"],
    "models": models,
}
json.dump(d, open(p, "w"), indent=2)
print(f"provider.ollama written ({len(models)} models)")
EOF
  opencode models ollama 2>/dev/null | grep -q "$AGENT_MODEL" \
    && log "ollama provider validated ($(opencode models ollama 2>/dev/null | grep -c . ) local models listed)." \
    || { warn "ollama provider NOT listing $AGENT_MODEL."; return 1; }
}

# Non-interactive agentic smoke test: local model must really edit a file.
# Least privilege: project-local config allows edits, denies shell.
opencode_smoke() {
  local model="ollama/$AGENT_MODEL"
  local scratch
  scratch="$(mktemp -d /tmp/oc-smoke.XXXXXX)"
  printf '{"permission":{"edit":"allow","bash":"deny"}}' > "$scratch/opencode.json"
  if opencode run --dir "$scratch" -m "$model" \
    "Create hello.py containing exactly print('OK'). Do not run anything." >/dev/null 2>&1; then
    if [[ -f "$scratch/hello.py" ]] && grep -q "print('OK')\|print(\"OK\")" "$scratch/hello.py"; then
      log "opencode smoke OK: $model created hello.py with local model only."
      rm -rf "$scratch"
      return 0
    fi
  fi
  warn "opencode smoke FAILED ($model did not create hello.py)."
  rm -rf "$scratch"
  return 1
}

verify() {
  log "--- Phase 4 verify ---"
  local fail=0
  if ! webui_up; then
    warn "open-webui: NOT reachable"
    return 1
  fi
  log "open-webui: reachable (:3000, $(curl -s --max-time 10 "$WEBUI_URL/api/version" | "$VENV_PY" -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null))"
  if [[ "$CHECK_ONLY" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    log "admin + RAG checks skipped (no-change mode)."
    command -v opencode >/dev/null 2>&1 && log "opencode: present" || warn "opencode: MISSING"
    return 0
  fi
  local token models
  token="$(webui_token)" || { warn "admin auth failed."; return 1; }
  models="$(curl -s --max-time 20 "$WEBUI_URL/api/models" -H "Authorization: Bearer $token")"
  if echo "$models" | grep -q "$CHAT_MODEL"; then
    log "UI model list includes $CHAT_MODEL (Ollama wiring OK)."
  else
    warn "UI model list MISSING $CHAT_MODEL."
    fail=1
  fi
  # End-to-end RAG: upload plan -> temp collection -> grounded chat -> cleanup.
  local fid kid answer
  fid="$(curl -s --max-time 60 -X POST "$WEBUI_URL/api/v1/files/" -H "Authorization: Bearer $token" \
    -F "file=@$ROOT_DIR/plans/local-intelligence-plan.md" \
    | "$VENV_PY" -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)"
  kid="$(curl -s --max-time 15 -X POST "$WEBUI_URL/api/v1/knowledge/create" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' -d '{"name":"phase4-probe","description":"automated verify, deleted after"}' \
    | "$VENV_PY" -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)"
  if [[ -n "$fid" && -n "$kid" ]] && curl -s --max-time 60 -X POST "$WEBUI_URL/api/v1/knowledge/$kid/file/add" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"file_id\":\"$fid\"}" >/dev/null; then
    log "probe collection built; asking grounded question (loads $CHAT_MODEL, ~1-3 min)..."
    answer="$(curl -s --max-time 300 -X POST "$WEBUI_URL/api/chat/completions" -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$CHAT_MODEL\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Which embedding model does the plan use? One sentence.\"}],\"files\":[{\"type\":\"collection\",\"id\":\"$kid\"}]}" \
      | "$VENV_PY" -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)"
    if echo "$answer" | grep -qiE "nomic|qwen3|bge-m3|embeddinggemma"; then
      log "RAG grounded answer OK: $(echo "$answer" | head -c 160)"
    else
      warn "RAG answer NOT grounded: $(echo "$answer" | head -c 200)"
      fail=1
    fi
    curl -s --max-time 15 -X DELETE "$WEBUI_URL/api/v1/knowledge/$kid/delete" \
      -H "Authorization: Bearer $token" >/dev/null 2>&1 || true
    log "probe collection removed."
  else
    warn "probe collection build FAILED."
    fail=1
  fi
  if command -v opencode >/dev/null 2>&1; then
    log "opencode: present ($(opencode --version 2>/dev/null || echo unknown)); running agentic smoke test..."
    opencode_smoke || fail=1
  else
    warn "opencode: MISSING (install step above)."
    fail=1
  fi
  if [[ "$fail" -eq 0 ]]; then
    log "Phase 4 OK: chat UI + RAG ready at http://localhost:3000."
  else
    warn "Phase 4 incomplete — see warnings above."
  fi
  if [[ "$ADMIN_PASSWORD" == "local-admin-changeme" ]]; then
    warn "default admin password in use — change it in the UI (admin panel)."
  fi
  return "$fail"
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --check-only) CHECK_ONLY=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $arg (try --help)" ;;
    esac
  done
  preflight
  local rc=0
  ensure_webui || rc=1
  ensure_opencode || rc=1
  # Verification runs at the end of every phase, even on partial failure.
  verify || rc=1
  [[ "$DRY_RUN" -eq 1 ]] && log "Done (dry run) — nothing changed."
  exit "$rc"
}

main "$@"
