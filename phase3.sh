#!/usr/bin/env bash
# phase3.sh — Phase 3 RAG services for local-intelligence-plan.md
# Starts Qdrant (pinned Docker image, persistent volume), installs the RAG
# Python deps into the project .venv, ingests the plan docs, and verifies a
# grounded retrieve loop. Idempotent — safe to re-run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$ROOT_DIR/.venv/bin/python"
QDRANT_IMAGE="qdrant/qdrant:v1.17.1"
QDRANT_NAME="qdrant"
QDRANT_URL="http://127.0.0.1:6333"
EMBED_MODEL="nomic-embed-text"

DRY_RUN=0
CHECK_ONLY=0
RECREATE=0

log() { printf '[phase3] %s\n' "$*"; }
warn() { printf '[phase3] WARN: %s\n' "$*" >&2; }
die() { printf '[phase3] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./phase3.sh [options]

Phase 3: Qdrant vector DB + RAG deps + ingest/verify demo.

Options:
  --dry-run    Show what would change, do nothing
  --check-only Verify current state, change nothing
  --recreate   Drop + rebuild the demo collection before ingest
  -h, --help   Show this help

Demo corpus is the project docs themselves:
  .venv/bin/python rag_demo.py --query "Which embedding models does the plan recommend?"
EOF
}

qdrant_up() {
  curl -sf --max-time 3 "$QDRANT_URL/healthz" >/dev/null 2>&1
}

preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Desktop for Mac, then re-run."
  docker info >/dev/null 2>&1 || die "docker daemon not running — open Docker Desktop, then re-run."
  [[ -x "$VENV_PY" ]] || die "project .venv missing — run ./phase1.sh first."
  curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 \
    || die "ollama server not reachable — run ./phase1.sh first."
  ollama show "$EMBED_MODEL" >/dev/null 2>&1 \
    || die "embedding model $EMBED_MODEL missing — run ./phase2.sh first."
  log "preflight OK (docker, .venv, ollama+$EMBED_MODEL)."
}

ensure_qdrant() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$QDRANT_NAME"; then
    log "qdrant container running."
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$QDRANT_NAME"; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "qdrant container STOPPED (check-only; would start it)."; return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then log "[dry-run] would run: docker start $QDRANT_NAME"; return 0; fi
    log "Starting stopped qdrant container..."
    docker start "$QDRANT_NAME" >/dev/null
  else
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "qdrant container MISSING (check-only; would run $QDRANT_IMAGE)."; return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: docker run -d $QDRANT_IMAGE (ports 6333/6334, volume qdrant_storage)"
      return 0
    fi
    log "Pulling $QDRANT_IMAGE..."
    docker pull "$QDRANT_IMAGE"
    log "Creating qdrant container (persistent volume qdrant_storage)..."
    docker run -d --name "$QDRANT_NAME" --restart unless-stopped \
      -p 6333:6333 -p 6334:6334 \
      -v qdrant_storage:/qdrant/storage \
      "$QDRANT_IMAGE" >/dev/null
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would wait for $QDRANT_URL/healthz"
    return 0
  fi
  local i
  for i in $(seq 1 30); do
    if qdrant_up; then log "qdrant REST reachable (:6333)."; return 0; fi
    sleep 1
  done
  warn "qdrant not answering on :6333 — see: docker logs $QDRANT_NAME"
  return 1
}

ensure_py() {
  # Pinned to the plan versions; the ollama adapter has no plan pin.
  local pkgs=("qdrant-client==1.17.1" "llama-index==0.14.22" "llama-index-embeddings-ollama")
  local missing=() p mod
  for p in "${pkgs[@]}"; do
    mod="$(echo "$p" | sed -E 's/^([a-zA-Z0-9_]+).*/\1/;s/-/_/g')"
    case "$p" in
      llama-index-embeddings-ollama) mod="llama_index.embeddings.ollama" ;;
      llama-index==*) mod="llama_index" ;;
      qdrant-client==*) mod="qdrant_client" ;;
    esac
    "$VENV_PY" -c "import $mod" >/dev/null 2>&1 || missing+=("$p")
  done
  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "RAG python deps present."
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "RAG deps MISSING (check-only; would pip install): ${missing[*]}"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run: .venv/bin/pip install ${missing[*]}"
    return 0
  fi
  log "Installing into project .venv: ${missing[*]}"
  "$ROOT_DIR/.venv/bin/pip" install "${missing[@]}"
}

run_demo() {
  if [[ "$CHECK_ONLY" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    log "demo ingest skipped (no-change mode)."
    return 0
  fi
  local args=(--ingest)
  [[ "$RECREATE" -eq 1 ]] && args+=(--recreate)
  log "Ingesting project docs into Qdrant..."
  "$VENV_PY" "$ROOT_DIR/rag_demo.py" "${args[@]}"
}

verify() {
  log "--- Phase 3 verify ---"
  local fail=0
  if qdrant_up; then
    log "qdrant REST: reachable (:6333)"
    local cols
    cols="$(curl -s --max-time 5 "$QDRANT_URL/collections")"
    if echo "$cols" | grep -q "local-intel"; then
      log "collection local-intel: present"
    else
      warn "collection local-intel: MISSING (run without --check-only to ingest)"
      fail=1
    fi
  else
    warn "qdrant REST: NOT reachable"
    fail=1
  fi
  if [[ "$CHECK_ONLY" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    log "RAG retrieve check skipped (no-change mode)."
    [[ "$fail" -eq 0 ]] || warn "Phase 3 incomplete — see warnings above."
    return "$fail"
  fi
  if "$VENV_PY" "$ROOT_DIR/rag_demo.py" --verify; then
    log "RAG retrieve: grounded in project docs."
  else
    warn "RAG retrieve check FAILED."
    fail=1
  fi
  if [[ "$fail" -eq 0 ]]; then
    log "Phase 3 OK: RAG stack ready."
  else
    warn "Phase 3 incomplete — see warnings above."
  fi
  return "$fail"
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --check-only) CHECK_ONLY=1 ;;
      --recreate) RECREATE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $arg (try --help)" ;;
    esac
  done
  preflight
  local rc=0
  ensure_qdrant || rc=1
  ensure_py || rc=1
  run_demo || rc=1
  # Verification runs at the end of every phase, even on partial failure.
  verify || rc=1
  [[ "$DRY_RUN" -eq 1 ]] && log "Done (dry run) — nothing changed."
  exit "$rc"
}

main "$@"
