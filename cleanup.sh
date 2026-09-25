#!/usr/bin/env bash
# cleanup.sh — uninstall existing local-intelligence software for a clean sheet
# Target: Mac Pro M4 Ultra, 128GB unified RAM, macOS Apple Silicon
# Covers everything named in plans/local-intelligence-plan.md:
#   runtimes (Ollama, LM Studio, llama.cpp, MLX/mlx-lm, llamafile, GPT4All),
#   models/caches, RAG services (Qdrant/Chroma), frontends (Open WebUI/LibreChat).
# Safe by default: dry-run unless --yes is passed. Idempotent — missing items are skipped.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=1
KEEP_MODELS=0
KEEP_DATA=0
SUDO=""

log() { printf '[cleanup] %s\n' "$*"; }
warn() { printf '[cleanup] WARN: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./cleanup.sh [options]

Remove existing local-intelligence software for a brand-new clean sheet.

Options:
  -y, --yes        Actually perform removals (required; without it this is a dry run)
      --dry-run    Show what would be removed, do nothing (default)
      --keep-models  Keep downloaded model weights (Ollama/LM Studio/HF/GPT4All)
      --keep-data    Keep RAG data volumes (Qdrant/Chroma storage dirs + volumes)
  -h, --help       Show this help

Examples:
  ./cleanup.sh                 # preview what would be removed
  ./cleanup.sh --yes           # full clean sheet
  ./cleanup.sh --yes --keep-models --keep-data  # remove apps, keep weights + RAG data
EOF
}

# run_cmd prints and optionally executes a shell command string.
run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[cleanup] [dry-run] %s\n' "$*"
  else
    printf '[cleanup] $ %s\n' "$*"
    eval "$*"
  fi
}

# needs_sudo_for reports 0 when path exists but is not removable without sudo.
needs_sudo_for() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 1
  [[ -w "$target" && -w "$(dirname "$target")" ]] || return 0
  return 1
}

# ensure_sudo asks for admin credentials ONCE upfront on live runs, so a
# protected shim (e.g. /usr/local/bin/ollama) can't fail midway with
# "Permission denied". Dry runs never prompt.
ensure_sudo() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  local candidates=(
    "/Applications/Ollama.app"
    "/Applications/LM Studio.app"
    "/Applications/GPT4All.app"
    "/Applications/Open WebUI.app"
    "/usr/local/bin/ollama"
    "/opt/homebrew/bin/ollama"
    "/usr/local/bin/lms"
    "/opt/homebrew/bin/lms"
    "/usr/local/bin/llama-server"
    "/usr/local/bin/llamafile"
  )
  local need=0
  local c
  for c in "${candidates[@]}"; do
    if needs_sudo_for "$c"; then need=1; break; fi
  done
  if [[ "$need" -eq 0 ]]; then return 0; fi
  log "Admin permissions needed for protected paths — requesting upfront (sudo -v)..."
  if sudo -v; then
    SUDO="sudo"
    log "Admin credentials cached for this run."
  else
    warn "sudo declined — protected paths may fail with Permission denied."
  fi
}

# rm_path removes a file/dir if it exists (respects dry-run).
# Uses sudo when the target needs it, and keeps going with a clear warning
# instead of aborting the whole cleanup on one stubborn path.
rm_path() {
  local p="$1"
  # Expand ~ and env vars without globbing surprises.
  local expanded
  expanded="$(eval echo "$p")"
  if [[ ! -e "$expanded" && ! -L "$expanded" ]]; then
    log "skip (not present): $expanded"
    return 0
  fi
  local prefix=""
  if needs_sudo_for "$expanded"; then prefix="sudo"; fi
  # A live run that hasn't cached sudo yet (e.g. path appeared after the
  # upfront check) still elevates here rather than failing.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$prefix" ]]; then
      printf '[cleanup] [dry-run] sudo rm -rf %q\n' "$expanded"
    else
      printf '[cleanup] [dry-run] rm -rf %q\n' "$expanded"
    fi
    return 0
  fi
  if [[ -n "$prefix" && -z "$SUDO" ]]; then
    log "Admin permissions needed for $expanded — requesting now..."
    if sudo -v; then SUDO="sudo"; else
      warn "FAILED (permission denied, sudo declined): $expanded"
      return 0
    fi
  fi
  local cmd=(rm -rf -- "$expanded")
  if [[ -n "$SUDO" && -n "$prefix" ]]; then
    printf '[cleanup] $ sudo rm -rf %q\n' "$expanded"
    if sudo rm -rf -- "$expanded"; then
      log "removed: $expanded"
    else
      warn "FAILED to remove: $expanded"
    fi
  else
    printf '[cleanup] $ rm -rf %q\n' "$expanded"
    if "${cmd[@]}"; then
      log "removed: $expanded"
    else
      warn "FAILED to remove: $expanded"
    fi
  fi
}

stop_processes() {
  log "Stopping local processes (if running)..."
  # pkill returns 1 when nothing matched; never fail the script on that.
  local procs=("ollama" "llama-server" "mlx_lm" "lms" "LM Studio" "GPT4All" "gpt4all" "llamafile" "open-webui")
  for p in "${procs[@]}"; do
    if pgrep -fi "$p" >/dev/null 2>&1; then
      local qp
      qp="$(printf '%q' "$p")"
      run_cmd "pkill -f $qp || true"
    else
      log "skip (not running): $p"
    fi
  done
}

stop_docker_services() {
  if ! command -v docker >/dev/null 2>&1; then
    log "skip docker stop/rm (docker not installed)"
    return
  fi
  local names="qdrant open-webui librechat"
  for n in $names; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$n"; then
      run_cmd "docker stop $n || true"
      run_cmd "docker rm -f $n || true"
    else
      log "skip (no container): $n"
    fi
  done
}

uninstall_brews() {
  if ! command -v brew >/dev/null 2>&1; then
    log "skip brew uninstalls (brew not installed)"
    return
  fi
  # Only uninstall formulae/casks that are actually installed.
  local formulae="ollama llama.cpp mlx qdrant gpt4all"
  for f in $formulae; do
    if brew list --formula "$f" >/dev/null 2>&1; then
      run_cmd "brew uninstall $f || true"
    else
      log "skip brew formula (not installed): $f"
    fi
  done
  local casks="ollama lm-studio gpt4all"
  for c in $casks; do
    if brew list --cask "$c" >/dev/null 2>&1; then
      run_cmd "brew uninstall --cask $c || true"
    else
      log "skip brew cask (not installed): $c"
    fi
  done
}

uninstall_pips() {
  # mlx-lm / mlx-serve / gpt4all / chroma / qdrant-client live in pip/uv/pipx envs.
  # Never nuke an env — just uninstall the known packages if present.
  local pkgs="mlx mlx-lm mlx-serve gpt4all qdrant-client chromadb llama-index langchain langgraph haystack-ai open-webui"
  local managers=()
  command -v pipx >/dev/null 2>&1 && managers+=("pipx")
  command -v uv >/dev/null 2>&1 && managers+=("uv")
  command -v pip3 >/dev/null 2>&1 && managers+=("pip3")
  if [[ ${#managers[@]} -eq 0 ]]; then
    log "skip python package uninstalls (no pip3/uv/pipx found)"
    return
  fi
  for pkg in $pkgs; do
    if pip3 show "$pkg" >/dev/null 2>&1; then
      if command -v uv >/dev/null 2>&1; then
        run_cmd "uv pip uninstall $pkg || true"
      else
        run_cmd "pip3 uninstall -y $pkg || true"
      fi
    else
      log "skip pip package (not installed): $pkg"
    fi
    if command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep -qx "$pkg"; then
      run_cmd "pipx uninstall $pkg || true"
    fi
  done
}

remove_apps() {
  log "Removing app bundles + CLI shims..."
  rm_path "/Applications/Ollama.app"
  rm_path "/Applications/LM Studio.app"
  rm_path "/Applications/GPT4All.app"
  rm_path "/Applications/Open WebUI.app"
  rm_path "/usr/local/bin/ollama"
  rm_path "/opt/homebrew/bin/ollama"
  rm_path "/usr/local/bin/lms"
  rm_path "/opt/homebrew/bin/lms"
  rm_path "/usr/local/bin/llama-server"
  rm_path "/usr/local/bin/llamafile"
  rm_path "$HOME/.local/bin/lms"
  rm_path "$HOME/llamafiles"
  rm_path "$ROOT_DIR/llamafiles"
  # llama.cpp build trees / binaries, if user built upstream manually
  rm_path "$ROOT_DIR/llama.cpp"
  rm_path "$HOME/llama.cpp"
}

remove_models_and_caches() {
  if [[ "$KEEP_MODELS" -eq 1 ]]; then
    log "Keeping model weights (--keep-models)."
    return
  fi
  log "Removing model weights + caches..."
  rm_path "$HOME/.ollama"
  rm_path "$HOME/.lmstudio"
  rm_path "$HOME/.lm-studio"
  rm_path "$HOME/.cache/lm-studio"
  rm_path "$HOME/.cache/huggingface"
  rm_path "$HOME/.cache/gpt4all"
  rm_path "$HOME/Library/Caches/Ollama"
  rm_path "$HOME/Library/Caches/LM Studio"
  rm_path "$HOME/Library/Caches/GPT4All"
  rm_path "$HOME/Library/Application Support/GPT4All"
  rm_path "$HOME/Library/Application Support/LM Studio"
  rm_path "$ROOT_DIR/models"
}

remove_rag_data() {
  if [[ "$KEEP_DATA" -eq 1 ]]; then
    log "Keeping RAG data (--keep-data)."
    return
  fi
  log "Removing RAG data dirs + docker volumes..."
  rm_path "$ROOT_DIR/qdrant_storage"
  rm_path "$ROOT_DIR/data/qdrant"
  rm_path "$ROOT_DIR/chroma_db"
  rm_path "$ROOT_DIR/data/chroma"
  rm_path "$ROOT_DIR/.chroma"
  if command -v docker >/dev/null 2>&1; then
    for v in qdrant_storage open-webui-data librechat-data; do
      if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v"; then
        run_cmd "docker volume rm $v || true"
      else
        log "skip docker volume (not present): $v"
      fi
    done
  fi
}

main() {
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) DRY_RUN=0 ;;
      --dry-run) DRY_RUN=1 ;;
      --keep-models) KEEP_MODELS=1 ;;
      --keep-data) KEEP_DATA=1 ;;
      -h|--help) usage; exit 0 ;;
      *) warn "unknown arg: $arg (try --help)"; usage; exit 1 ;;
    esac
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN — nothing will be removed. Pass --yes to execute."
  else
    log "LIVE RUN — removing software listed in plans/local-intelligence-plan.md."
    ensure_sudo
  fi

  stop_processes
  stop_docker_services
  uninstall_brews
  uninstall_pips
  remove_apps
  remove_models_and_caches
  remove_rag_data

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Done (dry run). Re-run with --yes to execute."
  else
    log "Done. Clean sheet ready for Phase 1."
  fi
}

main "$@"
