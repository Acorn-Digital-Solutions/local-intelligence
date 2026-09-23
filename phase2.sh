#!/usr/bin/env bash
# phase2.sh — Phase 2 models for local-intelligence-plan.md
# Pulls via Ollama: coder + reasoning + 70B fallback + embeddings (all Q4_K_M
# upstream defaults). Idempotent — skips models already present.
# Requires Phase 1 (ollama binary + server). Model pulls are large (~85GB
# total, ~43GB with --skip-70b); disk is checked before pulling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_URL="http://127.0.0.1:11434"

CODER_MODEL="qwen2.5-coder:32b"
REASON_MODEL="deepseek-r1:32b"
FALLBACK_MODEL="llama3.3:70b"
EMBED_MODEL="nomic-embed-text"
# Rough GB per model (Q4_K_M): coder 19, reasoning 19, fallback 42, embed <1.
EST_FULL_GB=85
EST_NO70B_GB=43

DRY_RUN=0
CHECK_ONLY=0
SKIP_70B=0
# Override set, e.g.: MODELS="qwen3:32b" ./phase2.sh
MODELS="${MODELS:-}"

log() { printf '[phase2] %s\n' "$*"; }
warn() { printf '[phase2] WARN: %s\n' "$*" >&2; }
die() { printf '[phase2] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./phase2.sh [options]

Phase 2: pull base + reasoning models via Ollama.

Options:
  --dry-run    Show what would be pulled, pull nothing
  --check-only Verify current state, pull nothing
  --skip-70b   Skip the 70B fallback pull (saves ~42GB)
  -h, --help   Show this help

Env:
  MODELS="a b c"  Pull this list instead of the defaults

Defaults: qwen2.5-coder:32b deepseek-r1:32b llama3.3:70b nomic-embed-text
EOF
}

expected_models() {
  if [[ -n "$MODELS" ]]; then
    echo "$MODELS"
    return 0
  fi
  local list="$CODER_MODEL $REASON_MODEL $EMBED_MODEL"
  if [[ "$SKIP_70B" -eq 0 ]]; then
    list="$list $FALLBACK_MODEL"
  fi
  echo "$list"
}

smoke_model() {
  if [[ -n "$MODELS" ]]; then
    echo "$MODELS" | awk '{print $1}'
  else
    echo "$CODER_MODEL"
  fi
}

server_up() {
  curl -sf --max-time 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1
}

model_present() {
  ollama show "$1" >/dev/null 2>&1
}

preflight() {
  command -v ollama >/dev/null 2>&1 || die "ollama not found — run ./phase1.sh first."
  server_up || die "ollama server not reachable (:11434) — run ./phase1.sh first."
  local key="${OLLAMA_MODELS:-$HOME/.ollama}/id_ed25519"
  [[ -f "$key" ]] || die "server identity key missing ($key) — pulls would fail. Run ./phase1.sh (restarts the server to regenerate it), then re-run phase 2."
  local server_v client_v
  server_v="$(curl -s --max-time 5 "$OLLAMA_URL/api/version" 2>/dev/null | sed 's/.*"version":"\([^"]*\)".*/\1/')"
  client_v="$(ollama --version 2>/dev/null | head -1)"
  log "server: ${server_v:-unknown} | client: ${client_v:-unknown}"
  if [[ -n "${server_v:-}" && "$client_v" != *"$server_v"* ]]; then
    warn "client/server version skew — if pulls misbehave: brew services restart ollama"
  fi
  local need_gb="$EST_FULL_GB"
  [[ "$SKIP_70B" -eq 1 ]] && need_gb="$EST_NO70B_GB"
  [[ -n "$MODELS" ]] && need_gb="?"
  local avail_gb
  avail_gb="$(df -g "${OLLAMA_MODELS:-$HOME}" 2>/dev/null | tail -1 | awk '{print $4}')"
  if [[ -n "${avail_gb:-}" && "$need_gb" != "?" && "$avail_gb" -lt "$need_gb" ]]; then
    warn "disk may be tight: ~${need_gb}GB needed, ${avail_gb}GB available."
  else
    log "disk available: ${avail_gb:-unknown}GB (need ~${need_gb}GB)."
  fi
}

pull_models() {
  local m
  for m in $(expected_models); do
    if model_present "$m"; then
      log "present, skipping pull: $m"
      continue
    fi
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "MISSING (check-only; would pull): $m"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: ollama pull $m"
      continue
    fi
    log "Pulling $m (large — this takes a while)..."
    if ollama pull "$m"; then
      log "pulled: $m"
    else
      warn "FAILED to pull $m — continuing; verify will flag it."
    fi
  done
}

verify() {
  log "--- Phase 2 verify ---"
  local fail=0 m
  for m in $(expected_models); do
    if model_present "$m"; then
      log "present: $m ($(ollama list 2>/dev/null | awk -v m="$m" '$1==m {print $3}'))"
    else
      warn "MISSING: $m"
      fail=1
    fi
  done
  if ! server_up; then
    warn "ollama server not reachable."
    return 1
  fi
  local sm
  sm="$(smoke_model)"
  if ! model_present "$sm"; then
    warn "smoke test skipped ($sm not present)."
    return "$fail"
  fi
  if [[ "$CHECK_ONLY" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    log "smoke test skipped (no-pull mode)."
    return "$fail"
  fi
  log "smoke test: tiny generate on $sm..."
  local resp
  resp="$(curl -s --max-time 600 "$OLLAMA_URL/api/generate" \
    -d "{\"model\":\"$sm\",\"prompt\":\"Reply with exactly: OK\",\"stream\":false,\"options\":{\"num_predict\":8}}")"
  if echo "$resp" | grep -q '"response":"[^"]'; then
    log "smoke test OK: $sm generated: $(echo "$resp" | sed 's/.*"response":"\([^"]*\)".*/\1/' | head -c 80)"
  else
    warn "smoke test FAILED on $sm: $(echo "$resp" | head -c 200)"
    fail=1
  fi
  if [[ "$fail" -eq 0 ]]; then
    log "Phase 2 OK: models ready."
  else
    warn "Phase 2 incomplete — see warnings above."
  fi
  return "$fail"
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --check-only) CHECK_ONLY=1 ;;
      --skip-70b) SKIP_70B=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $arg (try --help)" ;;
    esac
  done
  preflight
  local rc=0
  pull_models || rc=1
  # Verification runs at the end of every phase, even when pulls failed:
  # it reports exactly which models are missing instead of failing silent.
  verify || rc=1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Done (dry run) — nothing pulled."
  fi
  exit "$rc"
}

main "$@"
