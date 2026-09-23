#!/usr/bin/env bash
# local-intelligence-setup.sh — automate local-intelligence-plan.md
# Target: Mac Pro M4 Ultra, 128GB unified RAM, macOS Apple Silicon
# Step-by-step build: Phase 1 (base runtimes) -> Phase 2 (models) -> Phase 3 (RAG) -> Phase 4 (chat UI).
# Optimize lives outside setup: ./benchmark.sh (standalone).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="$ROOT_DIR/local-intelligence-plan.md"

log() { printf '[local-intelligence] %s\n' "$*"; }
die() { printf '[local-intelligence] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./local-intelligence-setup.sh [options]

Options:
  --phase1    Install base runtimes (Ollama + LM Studio check + MLX)
            Extra flags forwarded to phase1.sh: --dry-run --check-only
  --phase2    Pull base models (Qwen coder + embeddings)
            Extra flags forwarded to phase2.sh: --dry-run --check-only --skip-70b
  --phase3    Start RAG services (Qdrant)
            Extra flags forwarded to phase3.sh: --dry-run --check-only --recreate
  --phase4    Chat UI with RAG (Open WebUI + OpenCode)
            Extra flags forwarded to phase4.sh: --dry-run --check-only
  -h, --help  Show this help
EOF
}

# --- Phases (phase1 lives in phase1.sh; rest filled in step by step) ---
phase1() {
  local fwd=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run|--check-only) fwd+=("$a") ;;
    esac
  done
  log "Phase 1: base runtimes (Ollama + LM Studio + .venv/mlx-lm)"
  if ((${#fwd[@]})); then "$ROOT_DIR/phase1.sh" "${fwd[@]}"; else "$ROOT_DIR/phase1.sh"; fi
}
phase2() {
  local fwd=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run|--check-only|--skip-70b) fwd+=("$a") ;;
    esac
  done
  log "Phase 2: models (coder + reasoning + 70B fallback + embeddings)"
  if ((${#fwd[@]})); then "$ROOT_DIR/phase2.sh" "${fwd[@]}"; else "$ROOT_DIR/phase2.sh"; fi
}
phase3() {
  local fwd=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run|--check-only|--recreate) fwd+=("$a") ;;
    esac
  done
  log "Phase 3: RAG (Qdrant + deps + ingest/verify demo)"
  if ((${#fwd[@]})); then "$ROOT_DIR/phase3.sh" "${fwd[@]}"; else "$ROOT_DIR/phase3.sh"; fi
}
phase4() {
  local fwd=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run|--check-only) fwd+=("$a") ;;
    esac
  done
  log "Phase 4: chat UI with RAG (Open WebUI + OpenCode)"
  if ((${#fwd[@]})); then "$ROOT_DIR/phase4.sh" "${fwd[@]}"; else "$ROOT_DIR/phase4.sh"; fi
}

main() {
  [[ -f "$PLAN_FILE" ]] || die "plan file not found: $PLAN_FILE"
  [[ $# -eq 0 ]] && { usage; exit 0; }
  for arg in "$@"; do
    case "$arg" in
      --phase1) phase1 "$@" ;;
      --phase2) phase2 "$@" ;;
      --phase3) phase3 "$@" ;;
      --phase4) phase4 "$@" ;;

      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $arg (try --help)" ;;
    esac
  done
}

main "$@"
