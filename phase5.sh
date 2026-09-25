#!/usr/bin/env bash
# phase5.sh — LAN access for local-intelligence-plan.md
# Binds Ollama to all interfaces (it ships localhost-only) so other machines
# on the same local network can use it; confirms Open WebUI already publishes
# :3000 on all interfaces. Persists via the brew services env file
# (~/.homebrew/services/ollama.env), which brew merges into the launchd plist
# on every start/restart/upgrade. Direct plist edits do NOT survive:
# `brew services start` regenerates the plist from the formula template.
#
# SECURITY: Ollama has NO authentication — anyone on the LAN can use models
# AND administer them (pull/delete). Trusted home LAN only. Change the
# Open WebUI admin password in the UI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HOMEBREW_USER_CONFIG_HOME:-$HOME/.homebrew}/services/ollama.env"
WEBUI_URL="http://127.0.0.1:3000"

DRY_RUN=0
CHECK_ONLY=0

log() { printf '[phase5] %s\n' "$*"; }
warn() { printf '[phase5] WARN: %s\n' "$*" >&2; }
die() { printf '[phase5] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./phase5.sh [options]

Phase 5: expose Ollama + Open WebUI on the local network.

Options:
  --dry-run    Show what would change, do nothing
  --check-only Verify current state, change nothing
  -h, --help   Show this help

Afterwards, from another machine on the same LAN:
  Ollama:  http://<this-mac-ip>:11434   (API + OpenAI-compat /v1)
  WebUI:   http://<this-mac-ip>:3000    (login required)
EOF
}

lan_ip() {
  ipconfig getifaddr en0 2>/dev/null \
    || ipconfig getifaddr en1 2>/dev/null \
    || ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
}

# Stable mDNS name (tracks DHCP changes); empty when Bonjour is unavailable.
lan_name() {
  local h
  h="$(scutil --get LocalHostName 2>/dev/null || true)"
  [[ -n "$h" ]] && echo "$h.local" || true
}

ollama_lan_bound() {
  lsof -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -qE '\*:11434|0\.0\.0\.0:11434'
}

preflight() {
  curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 \
    || die "ollama server not reachable — run ./phase1.sh first."
  curl -sf --max-time 3 "$WEBUI_URL/health" >/dev/null 2>&1 \
    || die "open-webui not reachable — run ./phase4.sh first."
  [[ -n "$(lan_ip)" ]] || die "no LAN IP found — is Wi-Fi/Ethernet connected?"
  log "preflight OK (ollama, webui, LAN IP $(lan_ip))."
}

ensure_ollama_lan() {
  if ollama_lan_bound; then
    log "ollama already bound to all interfaces (:11434)."
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "ollama localhost-only (check-only; would set OLLAMA_HOST=0.0.0.0 + restart)."
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would set OLLAMA_HOST=0.0.0.0 in $ENV_FILE + brew services restart ollama"
    return 0
  fi
  brew services list 2>/dev/null | grep -q "ollama.*started" \
    || die "ollama is not brew-managed — start it via 'brew services start ollama' first."
  # Persist via the brew services env file, not the plist: `brew services
  # start/restart` regenerates the launchd plist from the formula template,
  # wiping direct plist edits (that is how a previous OLLAMA_HOST edit was
  # lost). Vars in the env file are merged back into the plist on every
  # start and survive upgrades (see `brew services --help`).
  mkdir -p "$(dirname "$ENV_FILE")"
  if [[ ! -f "$ENV_FILE" ]]; then
    printf '# Managed by local-intelligence phase5.sh - Ollama LAN bind.\nOLLAMA_HOST=0.0.0.0\n' > "$ENV_FILE"
  elif grep -q "^OLLAMA_HOST=" "$ENV_FILE"; then
    sed -i '' 's|^OLLAMA_HOST=.*|OLLAMA_HOST=0.0.0.0|' "$ENV_FILE"
  else
    [[ -z "$(tail -c 1 "$ENV_FILE")" ]] || printf '\n' >> "$ENV_FILE"
    printf 'OLLAMA_HOST=0.0.0.0\n' >> "$ENV_FILE"
  fi
  log "OLLAMA_HOST=0.0.0.0 persisted in $ENV_FILE."
  log "Restarting ollama with LAN bind..."
  if ! brew services restart ollama >/dev/null 2>&1; then
    warn "launchd bootstrap refused here (restricted shells can't bootstrap gui sessions)."
    warn "Run this from a login Terminal instead: brew services restart ollama"
    return 1
  fi
  local i
  for i in $(seq 1 20); do
    if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ollama_lan_bound; then
    log "ollama now bound to all interfaces (:11434)."
  else
    warn "ollama restarted but still localhost-only — check: brew services list; lsof -iTCP:11434"
    return 1
  fi
}

ensure_webui_lan() {
  if docker port open-webui 2>/dev/null | grep -q "0.0.0.0:3000"; then
    log "open-webui already published on 0.0.0.0:3000."
    return 0
  fi
  warn "open-webui NOT on all interfaces — recreate via ./phase4.sh (docker run -p 3000:8080)."
  return 1
}

firewall_note() {
  local state
  state="$(defaults read /Library/Preferences/com.apple.alf globalstate 2>/dev/null || echo unknown)"
  if [[ "$state" == "1" || "$state" == "2" ]]; then
    warn "macOS firewall is ON — allow incoming connections for Ollama/Docker when prompted, else LAN machines can't connect (System Settings > Network > Firewall)."
  else
    log "macOS firewall: off/unconfigured (no inbound block expected)."
  fi
}

verify() {
  log "--- Phase 5 verify ---"
  local fail=0 ip
  ip="$(lan_ip)"
  if curl -sf --max-time 5 "http://$ip:11434/api/version" >/dev/null 2>&1; then
    log "ollama reachable via LAN: http://$ip:11434"
  elif ollama_lan_bound; then
    log "ollama bound on all interfaces (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "ollama NOT reachable via LAN IP."
    fail=1
  fi
  if curl -sf --max-time 5 "http://$ip:3000/health" >/dev/null 2>&1; then
    log "open-webui reachable via LAN: http://$ip:3000"
  elif docker port open-webui 2>/dev/null | grep -q "0.0.0.0:3000"; then
    log "open-webui published on all interfaces (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "open-webui NOT reachable via LAN IP."
    fail=1
  fi
  firewall_note
  if [[ "$fail" -eq 0 ]]; then
    log "Phase 5 OK: LAN access ready."
    log "Other machines: Ollama http://$ip:11434 | WebUI http://$ip:3000"
    local name
    name="$(lan_name)"
    [[ -n "$name" ]] && log "Stable names (survive DHCP changes): Ollama http://$name:11434 | WebUI http://$name:3000"
    log "opencode elsewhere: provider baseURL http://$ip:11434/v1 (same LAN only)."
  else
    warn "Phase 5 incomplete — see warnings above."
  fi
  warn "Reminder: Ollama has no login — trusted LANs only."
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
  ensure_ollama_lan || rc=1
  ensure_webui_lan || rc=1
  # Verification runs at the end of every phase, even on partial failure.
  verify || rc=1
  [[ "$DRY_RUN" -eq 1 ]] && log "Done (dry run) — nothing changed."
  exit "$rc"
}

main "$@"
