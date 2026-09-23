#!/usr/bin/env bash
# phase1.sh — Phase 1 base runtimes for local-intelligence-plan.md
# Installs/verifies: Ollama (brew) + Ollama server, LM Studio (cask),
# project-local .venv with mlx-lm. Idempotent — safe to re-run.
# Target: macOS Apple Silicon. Model pulls are Phase 2, not here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
OLLAMA_URL="http://127.0.0.1:11434/api/tags"
# lms ships inside the app bundle but is never put on PATH by the installer.
LMS_BUNDLED="/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"
LOCAL_BIN="$HOME/.local/bin"
RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
PATH_MARKER="# local-intelligence PATH (managed by phase1.sh)"

DRY_RUN=0
CHECK_ONLY=0

log() { printf '[phase1] %s\n' "$*"; }
warn() { printf '[phase1] WARN: %s\n' "$*" >&2; }
die() { printf '[phase1] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./phase1.sh [options]

Phase 1: install + verify base runtimes (Ollama, LM Studio, .venv with mlx-lm).

Options:
  --dry-run    Show what would change, do nothing
  --check-only Verify current state, install nothing
  -h, --help   Show this help

Run instructions (project environment):
  source .venv/bin/activate
  python -c "import mlx_lm"
EOF
}

server_up() {
  curl -sf --max-time 3 "$OLLAMA_URL" >/dev/null 2>&1
}

# Path to the server identity key. A running server with this file missing
# (e.g. data dir wiped while it was up) answers /api/tags fine but fails
# every pull with "open .../id_ed25519: no such file or directory".
ollama_key() {
  echo "${OLLAMA_MODELS:-$HOME/.ollama}/id_ed25519"
}

wait_for_server() {
  local i
  for i in $(seq 1 15); do
    if server_up; then
      log "ollama server reachable (:11434)."
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_ollama_server() {
  log "Restarting ollama server (regenerates identity key, picks up current binary)..."
  if brew services restart ollama 2>/dev/null; then
    log "brew services restart ollama issued."
  else
    pkill -fi "ollama serve" 2>/dev/null || true
    sleep 2
    brew services start ollama || warn "brew services start failed — try manually: ollama serve"
  fi
  if wait_for_server; then
    return 0
  fi
  warn "ollama server still not reachable — start manually: ollama serve (logs: brew services list)."
  return 1
}

guard_os() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "not macOS (uname -s = $(uname -s)) — continuing, paths may differ."
  fi
  if [[ "$(uname -m)" != "arm64" ]]; then
    warn "not Apple Silicon (uname -m = $(uname -m)) — Metal/MLX assumptions may not hold."
  fi
}

require_brew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew not found — install from https://brew.sh then re-run."
  log "brew: $(brew --version | head -1)"
}

ensure_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    log "ollama present: $(ollama --version 2>/dev/null || echo unknown)"
  elif [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "ollama MISSING (check-only; would run: brew install ollama)."
    return 1
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run: brew install ollama"
  else
    log "Installing ollama..."
    brew install ollama
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would ensure ollama server on :11434"
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]] && ! command -v ollama >/dev/null 2>&1; then
    return 1
  fi
  if server_up; then
    log "ollama server reachable (:11434)."
    if [[ -f "$(ollama_key)" ]]; then
      return 0
    fi
    warn "server identity key missing ($(ollama_key)) — pulls would fail; restarting server to regenerate it."
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "check-only; would restart the server.";
      return 1
    fi
    restart_ollama_server || return 1
    [[ -f "$(ollama_key)" ]] || warn "identity key still missing after restart."
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "ollama server NOT reachable (check-only; would start it).";
    return 1
  fi
  log "Starting ollama server (brew services)..."
  brew services start ollama || warn "brew services start failed — try: ollama serve"
  wait_for_server || {
    warn "ollama server still not reachable — start manually: ollama serve (logs: brew services list)."
    return 1
  }
  return 0
}

ensure_lm_studio() {
  local present=0
  command -v lms >/dev/null 2>&1 && present=1
  [[ -d "/Applications/LM Studio.app" ]] && present=1
  if [[ "$present" -eq 1 ]]; then
    log "LM Studio present.$([[ -d '/Applications/LM Studio.app' ]] && echo ' (/Applications/LM Studio.app)' || true)"
    log "lms CLI wiring happens in the PATH step below."
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "LM Studio MISSING (check-only; would run: brew install --cask lm-studio)."
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run: brew install --cask lm-studio"
    return 0
  fi
  log "Installing LM Studio..."
  brew install --cask lm-studio
  log "LM Studio installed — open it once to finish setup."
}

# ensure_cli_path links the bundled lms onto PATH and persists every needed
# CLI dir (ours, LM Studio's own future ~/.lmstudio/bin, brew's) for new shells.
ensure_cli_path() {
  local fail=0
  if command -v lms >/dev/null 2>&1; then
    log "lms on PATH: $(command -v lms)"
  elif [[ -x "$LMS_BUNDLED" ]]; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "lms NOT on PATH (check-only; would link bundled binary into $LOCAL_BIN)."
      fail=1
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: mkdir -p $LOCAL_BIN && ln -sf <bundled-lms> $LOCAL_BIN/lms"
    else
      mkdir -p "$LOCAL_BIN"
      ln -sf "$LMS_BUNDLED" "$LOCAL_BIN/lms"
      log "lms linked: $LOCAL_BIN/lms"
    fi
  else
    warn "no lms anywhere (not on PATH, no bundled binary) — open LM Studio once and install the CLI from the app."
    fail=1
  fi

  local candidates=("$LOCAL_BIN" "$HOME/.lmstudio/bin" "/opt/homebrew/bin" "/usr/local/bin")
  local to_add=() d
  for d in "${candidates[@]}"; do
    if [[ -d "$d" ]] && [[ ":$PATH:" != *":$d:"* ]]; then
      to_add+=("$d")
    fi
  done
  if [[ "${#to_add[@]}" -eq 0 ]]; then
    log "PATH already covers all needed CLI dirs."
  elif [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "PATH missing (check-only; would add): ${to_add[*]}"
    fail=1
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would prepend to PATH (this shell + $RC_FILE): ${to_add[*]}"
  else
    local IFS=:
    export PATH="${to_add[*]}:$PATH"
    unset IFS
    hash -r 2>/dev/null || true
    log "PATH updated for this run: ${to_add[*]}"
    local line="export PATH=\"$LOCAL_BIN:\$HOME/.lmstudio/bin:\$PATH\""
    if [[ -f "$RC_FILE" ]] && grep -qF "$PATH_MARKER" "$RC_FILE"; then
      log "PATH already persisted in $RC_FILE."
    else
      { echo ""; echo "$PATH_MARKER"; echo "$line"; } >> "$RC_FILE"
      log "PATH persisted in $RC_FILE (restart shell or: source $RC_FILE)."
    fi
  fi
  if command -v lms >/dev/null 2>&1; then
    log "lms resolves: $(command -v lms)"
  elif [[ "$DRY_RUN" -eq 0 && "$CHECK_ONLY" -eq 0 ]]; then
    warn "lms still not resolving on PATH."
    fail=1
  fi
  return "$fail"
}

ensure_venv_mlx() {
  # Project-local environment per repo convention: .venv at project root.
  if [[ ! -d "$VENV_DIR" ]]; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn ".venv MISSING (check-only; would create it)."
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] would run: python3 -m venv .venv"
      log "[dry-run] would run: .venv/bin/pip install -U mlx-lm"
      return 0
    else
      log "Creating project .venv..."
      if command -v uv >/dev/null 2>&1; then
        uv venv "$VENV_DIR"
      else
        python3 -m venv "$VENV_DIR"
      fi
    fi
  else
    log ".venv present."
  fi
  if [[ "$DRY_RUN" -eq 1 || "$CHECK_ONLY" -eq 1 ]]; then
    if [[ -x "$VENV_DIR/bin/python" ]] && "$VENV_DIR/bin/python" -c "import mlx_lm" >/dev/null 2>&1; then
      log "mlx_lm importable in .venv."
    else
      warn "mlx_lm NOT importable in .venv$([[ "$CHECK_ONLY" -eq 1 ]] && echo ' (check-only)' || echo ' (would install)')".
    fi
    return 0
  fi
  if "$VENV_DIR/bin/python" -c "import mlx_lm" >/dev/null 2>&1; then
    log "mlx_lm already importable in .venv."
    return 0
  fi
  log "Installing mlx-lm into .venv (best-effort; no wheel may exist for this Python)..."
  if "$VENV_DIR/bin/pip" install -U mlx-lm; then
    log "mlx-lm installed."
  else
    warn "mlx-lm install failed (e.g. no wheel for $(python3 --version)). Ollama/LM Studio remain usable; retry after creating .venv with a supported Python (3.11-3.13)."
  fi
}

verify() {
  log "--- Phase 1 verify ---"
  local fail=0
  if command -v ollama >/dev/null 2>&1; then
    log "ollama: $(ollama --version 2>/dev/null || echo unknown)"
    if server_up; then
      log "ollama server: reachable (:11434)"
    else
      warn "ollama server: NOT reachable"
      fail=1
    fi
  else
    warn "ollama: MISSING"
    fail=1
  fi
  if command -v lms >/dev/null 2>&1; then
    log "lms: $(command -v lms) ($(lms --version 2>/dev/null || echo version-unknown))"
  elif [[ -d "/Applications/LM Studio.app" ]]; then
    warn "LM Studio: app present, lms CLI not on PATH"
    fail=1
  else
    warn "LM Studio: MISSING"
    fail=1
  fi
  if [[ -x "$VENV_DIR/bin/python" ]] && "$VENV_DIR/bin/python" -c "import mlx_lm" >/dev/null 2>&1; then
    log "mlx_lm: importable in .venv"
  else
    warn "mlx_lm: NOT importable in .venv (non-blocking)"
  fi
  if [[ "$fail" -eq 0 ]]; then
    log "Phase 1 OK: base runtimes ready."
  else
    warn "Phase 1 incomplete — see warnings above."
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
  guard_os
  require_brew
  local rc=0
  ensure_ollama || rc=1
  ensure_lm_studio || rc=1
  ensure_cli_path || rc=1
  ensure_venv_mlx || rc=1
  verify || rc=1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Done (dry run) — nothing changed."
  fi
  exit "$rc"
}

main "$@"
