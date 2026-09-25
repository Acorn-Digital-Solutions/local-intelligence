#!/usr/bin/env bash
# client-setup.sh — set up a CLIENT machine against a local-intelligence server.
# Needs this script plus the configs/ directory beside it (no full repo
# checkout). Supports macOS (needs Homebrew) and Linux (apt- or dnf-based).
# Windows: use WSL2, then follow the Linux path. Requires VS Code already
# installed (with the `code` CLI on PATH) — the script does not install it.
#
# Installs + configures, all pointed at the server:
#   - Continue extension + ~/.continue/config.yaml
#     (models via http://SERVER:11434, RAG via http://SERVER:8011/mcp)
#   - opencode + ~/.config/opencode/opencode.jsonc (same server wiring)
#
# Get it onto the client (server's repo root has both):
#   scp -r client-setup.sh configs user@client:~/local-intel-client/ \
#     && ssh user@client 'bash ~/local-intel-client/client-setup.sh'
# Server prerequisites (else the script warns/fails): Ollama reachable at
# SERVER:11434 (phase 5) and the RAG MCP service at SERVER:8011 (plan section 9).
set -euo pipefail

SERVER="${SERVER_HOST:-compute.local}"
MCP_PORT="${MCP_PORT:-8011}"
DRY_RUN=0
CHECK_ONLY=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLIENT_CONFIG_DIR:-$SCRIPT_DIR/configs}"

log() { printf '[client-setup] %s\n' "$*"; }
warn() { printf '[client-setup] WARN: %s\n' "$*" >&2; }
die() { printf '[client-setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash client-setup.sh [options]

Options:
  --server HOST  local-intelligence server (default: compute.local,
                 env SERVER_HOST). Fall back to its LAN IP if mDNS fails.
  --mcp-port P   RAG MCP port on the server (default: 8011, env MCP_PORT)
  --dry-run      Print what would change, do nothing
  --check-only   Verify server reachability + what is installed, change nothing
  -h, --help     Show this help
EOF
}

OS="unknown"
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then OS="linux-apt"
      elif command -v dnf >/dev/null 2>&1; then OS="linux-dnf"
      else die "Linux without apt or dnf — install VS Code + opencode manually."
      fi ;;
    *) die "unsupported OS: $(uname -s) (Windows: use WSL2, then the Linux path)." ;;
  esac
}

server_up() { curl -sf --max-time 5 "http://$SERVER:11434/api/tags" >/dev/null 2>&1; }
mcp_up() { curl -s --max-time 5 -o /dev/null "http://$SERVER:$MCP_PORT/mcp" 2>/dev/null; }

preflight() {
  [[ -f "$CONFIG_DIR/continue-client-config.yaml" && -f "$CONFIG_DIR/opencode-client-defaults.json" ]] \
    || die "configs/ not found beside the script (want $CONFIG_DIR) — copy the script AND the configs directory (see header)."
  server_up || die "server Ollama unreachable at http://$SERVER:11434 — check the server (phase 5) and --server."
  if mcp_up; then
    log "server RAG MCP reachable at http://$SERVER:$MCP_PORT/mcp."
  else
    warn "server RAG MCP NOT reachable at http://$SERVER:$MCP_PORT/mcp — retrieval tools will fail until the server runs it (plan section 9)."
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 not found — install it first."
  log "preflight OK (OS: $OS, server: $SERVER)."
}

install_continue() {
  if ! command -v code >/dev/null 2>&1; then
    warn "VS Code ('code') not found — install VS Code first, then re-run for the Continue extension."
    return 1
  fi
  if code --list-extensions 2>/dev/null | grep -qi '^Continue\.continue'; then
    log "Continue extension present."
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then log "[dry-run] would run: code --install-extension Continue.continue"; return 0; fi
    code --install-extension Continue.continue
    log "Continue extension installed."
  fi
}

write_continue_config() {
  local cfg="$HOME/.continue/config.yaml"
  if [[ "$DRY_RUN" -eq 1 ]]; then log "[dry-run] would write $cfg (backup first if present)"; return 0; fi
  mkdir -p "$HOME/.continue"
  if [[ -f "$cfg" ]]; then
    cp -p "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"
    log "backed up existing $cfg."
  fi
  sed "s/__SERVER__/$SERVER/g; s/__MCP_PORT__/$MCP_PORT/g" \
    "$CONFIG_DIR/continue-client-config.yaml" > "$cfg"
  log "wrote $cfg."
}

install_opencode() {
  if command -v opencode >/dev/null 2>&1; then log "opencode present: $(opencode --version 2>/dev/null || echo unknown)"; return 0; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then log "[dry-run] would install opencode (brew, else install script)"; return 0; fi
  if command -v brew >/dev/null 2>&1 && brew install opencode; then
    log "opencode installed via brew."
  else
    log "brew unavailable/failed — using the installer script..."
    curl -fsSL https://opencode.ai/install | bash
  fi
  command -v opencode >/dev/null 2>&1 || die "opencode install failed."
}

write_opencode_config() {
  local cfg="$HOME/.config/opencode/opencode.jsonc"
  if [[ "$DRY_RUN" -eq 1 ]]; then log "[dry-run] would merge provider.ollama + mcp.rag into $cfg"; return 0; fi
  mkdir -p "$(dirname "$cfg")"
  if [[ -f "$cfg" ]]; then
    cp -p "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"
    log "backed up existing $cfg."
  fi
  SERVER="$SERVER" MCP_PORT="$MCP_PORT" OPENCODE_CFG="$cfg" \
    CLIENT_DEFAULTS="$CONFIG_DIR/opencode-client-defaults.json" python3 - <<'EOF'
import json, os, urllib.request
server, port, p = (os.environ["SERVER"], os.environ["MCP_PORT"],
                   os.environ["OPENCODE_CFG"])
defs = json.load(open(os.environ["CLIENT_DEFAULTS"]))
with urllib.request.urlopen(f"http://{server}:11434/api/tags", timeout=15) as r:
    names = [m["name"] for m in json.load(r).get("models", [])]
agents = set(defs["model_order"])
models = {}
for m in names:
    if any(s in m for s in defs.get("skip_substrings", [])):
        continue
    agentic = m in agents
    models[m] = {
        "name": m + (defs["agentic_name_suffix"] if agentic else defs["model_name_suffix"]),
        "tool_call": agentic,
        "limit": defs["default_limit"],
    }
if not models:
    raise SystemExit("no chat models on server (is Ollama serving any?)")
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
except ValueError as e:
    raise SystemExit(f"refusing to touch {p} (not plain JSON): {e}")
d.setdefault("$schema", "https://opencode.ai/config.json")
order = defs["model_order"]
default = next((f"ollama/{m}" for m in order if m in models), None)
if default:
    d["model"] = default
small = defs.get("small_model")
small = f"ollama/{small}" if small in models else default
if small:
    d["small_model"] = small
print(f"default model: {default}, small model: {small}")
provs = d.setdefault("provider", {})
provs["ollama"] = {
    "npm": defs["npm"],
    "name": defs["provider_name"],
    "options": {"baseURL": f"http://{server}:11434/v1"},
    "models": models,
}
d.setdefault("mcp", {})[defs.get("mcp_name", "rag")] = {
    "type": "remote", "url": f"http://{server}:{port}/mcp"}
json.dump(d, open(p, "w"), indent=2)
print(f"provider.ollama + mcp.rag written ({len(models)} models)")
EOF
  log "wrote $cfg."
}

verify() {
  local fail=0
  command -v code >/dev/null 2>&1 && log "code: present" || { warn "code: MISSING"; fail=1; }
  code --list-extensions 2>/dev/null | grep -qi '^Continue\.continue' \
    && log "Continue extension: installed" || { warn "Continue extension: MISSING"; fail=1; }
  [[ -f "$HOME/.continue/config.yaml" ]] && log "Continue config: present" || { warn "Continue config: MISSING"; fail=1; }
  if command -v opencode >/dev/null 2>&1; then
    opencode models ollama 2>/dev/null | grep -q "muse-glimmer" \
      && log "opencode ollama provider: $(opencode models ollama 2>/dev/null | grep -c .) models" \
      || { warn "opencode ollama provider: NOT listing server models"; fail=1; }
    local defmod
    defmod="$(grep -o '"model": *"[^"]*"' "$HOME/.config/opencode/opencode.jsonc" 2>/dev/null | head -n 1)"
    if [[ -n "$defmod" ]]; then log "opencode default: $defmod"; else warn "opencode default model: NOT SET"; fail=1; fi
  else
    warn "opencode: MISSING"; fail=1
  fi
  mcp_up && log "RAG MCP: reachable" || warn "RAG MCP: unreachable (server-side, plan section 9)"
  if [[ "$fail" -eq 0 ]]; then
    log "client setup OK. Next: open VS Code, new Continue Agent session (Glimmer), or: opencode run -m ollama/muse-glimmer:30b-mlx \"...\""
  else
    warn "client setup incomplete — see warnings above."
  fi
  return "$fail"
}

# Live retrieval verification (normal runs only; skipped under --check-only
# because it takes minutes against the server models).
verify_retrieval() {
  local fail=0
  # 1. opencode must show the rag server connected.
  if opencode mcp list 2>/dev/null | grep -qi 'rag'; then
    log "opencode MCP: rag server listed."
  else
    warn "opencode MCP: rag server NOT listed."; fail=1
  fi
  # 2. Functional probe: read-only scratch project (edit+bash denied, so a
  # grounded answer can only come through the rag MCP tools).
  if opencode models ollama 2>/dev/null | grep -q "muse-glimmer"; then
    local scratch runlog timeout_bin=""
    scratch="$(mktemp -d /tmp/rag-probe.XXXXXX)"
    runlog="$scratch/run.log"
    printf '{"permission":{"edit":"deny","bash":"deny"}}' > "$scratch/opencode.json"
    command -v timeout >/dev/null 2>&1 && timeout_bin="timeout 300"
    command -v gtimeout >/dev/null 2>&1 && timeout_bin="gtimeout 300"
    log "retrieval probe: querying 'alice' via rag MCP tools (up to 5 min)..."
    if [[ -n "$timeout_bin" ]]; then
      # shellcheck disable=SC2086
      $timeout_bin opencode run --dir "$scratch" -m ollama/muse-glimmer:30b-mlx \
        --format json "Use your rag MCP tools: list the collections, then query collection 'alice' for 'who chases Alice at the start?'. Report the collection names and the top answer." \
        >"$runlog" 2>&1 || warn "probe run exited nonzero (see below)."
    else
      warn "no timeout binary — running probe uncapped."
      opencode run --dir "$scratch" -m ollama/muse-glimmer:30b-mlx \
        --format json "Use your rag MCP tools: list the collections, then query collection 'alice' for 'who chases Alice at the start?'. Report the collection names and the top answer." \
        >"$runlog" 2>&1 || warn "probe run exited nonzero (see below)."
    fi
    if grep -q '"tool":"rag' "$runlog" 2>/dev/null && grep -qi 'rabbit' "$runlog" 2>/dev/null; then
      log "retrieval probe: PASS (rag tools called, White Rabbit grounded)."
    else
      warn "retrieval probe: FAIL — log kept at $runlog."; fail=1
    fi
    [[ "$fail" -eq 0 ]] && rm -rf "$scratch" || log "scratch kept at $scratch for inspection."
  else
    warn "retrieval probe: skipped (glimmer not served)."; fail=1
  fi
  # 3. Continue can only be checked statically here — the live half needs
  # the VS Code GUI, so print the exact manual step.
  local cfg="$HOME/.continue/config.yaml"
  if grep -q 'mcpServers:' "$cfg" 2>/dev/null && grep -q "$SERVER:$MCP_PORT/mcp" "$cfg" 2>/dev/null; then
    log "Continue config: remote rag MCP entry present."
  else
    warn "Continue config: rag MCP entry MISSING."; fail=1
  fi
  log "Manual (VS Code GUI): new Continue Agent session (Muse Glimmer 30B), ask: \"Using the rag tools, query collection 'alice' for who is accused of stealing the tarts, and cite the source chunk.\" Pass = rag_query called, Knave of Hearts answered."
  [[ "$fail" -eq 0 ]] && log "retrieval verification: PASS." || warn "retrieval verification: INCOMPLETE."
  return "$fail"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server) SERVER="$2"; shift 2 ;;
      --mcp-port) MCP_PORT="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --check-only) CHECK_ONLY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $1 (try --help)" ;;
    esac
  done
  # The server is LAN-local: never route it through an HTTP(S) proxy
  # (corporate laptops often export proxy env vars that break .local).
  export no_proxy="${no_proxy:+$no_proxy,}$SERVER"
  export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$SERVER"
  detect_os
  preflight
  if [[ "$CHECK_ONLY" -eq 1 ]]; then verify; exit "$?"; fi
  install_continue || warn "continuing without the Continue extension."
  write_continue_config
  install_opencode
  write_opencode_config
  local rc=0
  verify || rc=1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run retrieval verification (live MCP probe)."
  else
    verify_retrieval || rc=1
  fi
  exit "$rc"
}

main "$@"
