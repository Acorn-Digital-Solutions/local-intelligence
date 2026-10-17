#!/usr/bin/env bash
# phase5.sh — LAN access for plans/local-intelligence-plan.md
# Binds Ollama to all interfaces (it ships localhost-only) so other machines
# on the same local network can use it; confirms Open WebUI already publishes
# :3000 on all interfaces; serves the WebUI on port 80 too (Caddy -> :3000)
# so browsers just use http://compute.local; pins the mDNS name to
# compute.local so clients (client-setup.sh defaults to SERVER=compute.local)
# survive DHCP changes.
# Persists via the brew services env file
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
WEBUI_LOGS_PORT="8013"
WEBUI_LOGS_LABEL="org.local-intel.webui-logs"

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
  Ollama:  http://compute.local:11434   (API + OpenAI-compat /v1)
  Ollama:  http://compute.local/ollama/api  (no port; OpenAI-compat baseURL .../ollama/v1)
  Logs:    http://compute.local/logs/ollama       (raw ollama service log)
         http://compute.local/logs/caddy        (caddy log, incl. access lines)
         http://compute.local/logs/agent-tools  (agent-tools MCP log)
         http://compute.local/logs/webui[?tail=N] (open-webui container log)
  Docs:    http://compute.local/docs/            (docs site + logs viewer)
         http://compute.local/docs/readme.html (rendered README)
         http://compute.local/docs/README.md   (raw README source)
  WebUI:   http://compute.local         (login required; port 80 via Caddy)
  WebUI:   http://compute.local:3000    (direct to container)
  (this-mac-ip works too; the .local name survives DHCP changes)
EOF
}

lan_ip() {
  local iface
  iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
  if [[ -n "$iface" ]]; then
    ipconfig getifaddr "$iface" 2>/dev/null && return 0
  fi
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

EXPECTED_HOST="compute"

# Pin the mDNS name so re-running setup can never silently lose it
# (macOS renames on Bonjour conflicts, e.g. "compute (2)").
ensure_hostname() {
  local current
  current="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [[ "$current" == "$EXPECTED_HOST" ]]; then
    log "hostname already $EXPECTED_HOST.local."
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "LocalHostName is '$current' (check-only; would set $EXPECTED_HOST via scutil)."
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run: sudo scutil --set LocalHostName/ComputerName/HostName $EXPECTED_HOST[.*]"
    return 0
  fi
  log "setting hostname to $EXPECTED_HOST.local (needs admin)..."
  if sudo scutil --set LocalHostName "$EXPECTED_HOST" \
     && sudo scutil --set ComputerName "$EXPECTED_HOST" \
     && sudo scutil --set HostName "$EXPECTED_HOST.local"; then
    log "hostname now $EXPECTED_HOST.local."
  else
    warn "could not set hostname here — run in your own Terminal:"
    warn "  sudo scutil --set LocalHostName $EXPECTED_HOST && sudo scutil --set ComputerName $EXPECTED_HOST && sudo scutil --set HostName $EXPECTED_HOST.local"
    return 1
  fi
}

# The server is LAN-local: never probe it through an HTTP(S) proxy.
# Corporate shells often export http_proxy with a loopback-only no_proxy,
# which turns every .local/LAN-IP probe into a proxy 503. Subprocess-scoped.
unproxy_lan() {
  local ip name
  ip="$(lan_ip 2>/dev/null || true)"
  name="$(lan_name 2>/dev/null || true)"
  local add="*.local${name:+,$name}${ip:+,$ip}"
  export no_proxy="${no_proxy:+$no_proxy,}$add"
  export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$add"
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

webui_root_up() {
  curl -sf --max-time 3 http://127.0.0.1/health >/dev/null 2>&1
}

# Content-checked via tmp file (never `curl|grep -q`: with pipefail, grep
# exiting early can SIGPIPE curl into a spurious failure). The WebUI SPA
# fallback answers unknown :80 paths with HTTP 200, so bare reachability
# checks would false-green — every probe below asserts response SHAPE.
version_match() {
  local url="$1" tmp
  tmp="$(mktemp)" || return 1
  if curl -sf --max-time 5 -o "$tmp" "$url" 2>/dev/null \
     && grep -q '"version"[[:space:]]*:' "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

ollama_root_up() { version_match http://127.0.0.1/ollama/api/version; }

# Fetch a logs URL and confirm its body is a byte-prefix of the live file
# (the WebUI SPA fallback answers unknown :80 paths with HTTP 200, so a
# bare reachability check would false-green).
logs_match() {
  local url="$1" file="$2" tmp size
  [[ -f "$file" ]] || return 1
  tmp="$(mktemp)" || return 1
  if curl -sf --max-time 15 -o "$tmp" "$url" 2>/dev/null; then
    size="$(wc -c < "$tmp" | tr -d ' ')"
    if [[ "$size" -gt 0 ]] && head -c "$size" "$file" 2>/dev/null | cmp -s - "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

brew_var_log() {
  echo "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/var/log"
}

ollama_logs_match() { logs_match "$1" "$(brew_var_log)/ollama.log"; }
caddy_logs_match() { logs_match "$1" "$(brew_var_log)/caddy.log"; }
agent_logs_match() { logs_match "$1" /tmp/agent-tools-mcp.log; }

ollama_logs_up() { ollama_logs_match http://127.0.0.1/logs/ollama; }
caddy_logs_up() { caddy_logs_match http://127.0.0.1/logs/caddy; }
agent_logs_up() { agent_logs_match http://127.0.0.1/logs/agent-tools; }

# WebUI log has no local file (Docker owns it), so these probes look for the
# RFC3339 timestamps the helper forces via `docker logs --timestamps` —
# the SPA fallback's HTML never matches.
webui_match() {
  local url="$1" tmp
  tmp="$(mktemp)" || return 1
  if curl -sf --max-time 5 -o "$tmp" "$url" 2>/dev/null \
     && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

webui_logs_backend_up() { webui_match "http://127.0.0.1:$WEBUI_LOGS_PORT/?tail=5"; }

webui_logs_up() { webui_match 'http://127.0.0.1/logs/webui?tail=5'; }

docs_match() {
  local url="$1" tmp
  tmp="$(mktemp)" || return 1
  if curl -sf --max-time 5 -o "$tmp" "$url" 2>/dev/null \
     && grep -q '<title>Local Intelligence</title>' "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

docs_up() { docs_match http://127.0.0.1/docs/; }

readme_match() {
  local url="$1" tmp
  tmp="$(mktemp)" || return 1
  if curl -sf --max-time 5 -o "$tmp" "$url" 2>/dev/null \
     && grep -q '^# local-intelligence' "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

readme_up() { readme_match http://127.0.0.1/docs/README.md; }

viewer_match() {
  local url="$1" tmp
  tmp="$(mktemp)" || return 1
  if curl -sf --max-time 5 -o "$tmp" "$url" 2>/dev/null \
     && grep -q '<title>README — Local Intelligence</title>' "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

viewer_up() { viewer_match http://127.0.0.1/docs/readme.html; }

caddy_caddyfile() {
  echo "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/etc/Caddyfile"
}

# The /logs/webui route needs the tiny helper that serves `docker logs`
# (Docker Desktop keeps container logs inside its VM — no file to serve).
# User-level launchd service, loopback-only; Caddy is the LAN entry.
ensure_webui_logs() {
  if webui_logs_backend_up; then
    log "webui-logs helper already running (:8013)."
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "webui-logs helper MISSING (check-only; would install the launchd service)."
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run: install $WEBUI_LOGS_LABEL plist; launchctl bootstrap"
    return 0
  fi
  [[ -f "$ROOT_DIR/webui-logs.launchd.plist" ]] || { warn "helper plist missing: $ROOT_DIR/webui-logs.launchd.plist"; return 1; }
  [[ -f "$ROOT_DIR/webui_logs.py" ]] || { warn "helper script missing: $ROOT_DIR/webui_logs.py"; return 1; }
  local plist="$HOME/Library/LaunchAgents/$WEBUI_LOGS_LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  local tmp
  tmp="$(mktemp)" || { warn "mktemp failed."; return 1; }
  sed "s|__ROOT__|$ROOT_DIR|g" "$ROOT_DIR/webui-logs.launchd.plist" > "$tmp"
  if [[ ! -f "$plist" ]] || ! cmp -s "$tmp" "$plist"; then
    log "installing $plist..."
    cp "$tmp" "$plist" || { warn "cannot write $plist."; rm -f "$tmp"; return 1; }
  else
    log "helper plist already installed."
  fi
  rm -f "$tmp"
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$WEBUI_LOGS_LABEL" >/dev/null 2>&1 || true
  if launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
    log "webui-logs helper bootstrapped."
  else
    warn "launchd bootstrap refused here (restricted shells can't bootstrap gui sessions)."
    warn "Run this from a login Terminal instead: ./phase5.sh"
    warn "(or manually: launchctl bootstrap $domain $plist)"
    return 1
  fi
  local i
  for i in $(seq 1 10); do
    if webui_logs_backend_up; then
      log "webui-logs helper answering (:8013)."
      return 0
    fi
    sleep 1
  done
  warn "helper installed but :8013 not answering — see: tail /tmp/webui-logs.log"
  return 1
}

# Serve the WebUI + Ollama API + all service logs on port 80
# (http://compute.local, no port) via Caddy: / -> :3000 container,
# /ollama/* -> :11434 (prefix stripped), /logs/* -> raw service logs.
# No sudo needed: the user-level brew service binds :80 fine on this Mac.
# NOTE: no early return when :80 is up — the installed Caddyfile must be
# refreshed and caddy restarted whenever the template gains a route.
ensure_webui_root() {
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if webui_root_up; then
      log "web UI already served on port 80 (http://compute.local)."
    else
      warn "port-80 proxy MISSING (check-only; would install Caddy + proxy :80)."
      return 1
    fi
    if ollama_root_up; then
      log "ollama route already served on port 80 (http://compute.local/ollama/api)."
    else
      warn "port-80 ollama route MISSING (check-only; the Caddyfile route is not live)."
      return 1
    fi
    if ollama_logs_up; then
      log "ollama logs already served on port 80 (http://compute.local/logs/ollama)."
    else
      warn "port-80 ollama-logs route MISSING (check-only; the Caddyfile route is not live)."
      return 1
    fi
    if caddy_logs_up; then
      log "caddy log already served on port 80 (http://compute.local/logs/caddy)."
    else
      warn "port-80 caddy-log route MISSING (check-only; the Caddyfile route is not live)."
      return 1
    fi
    if agent_logs_up; then
      log "agent-tools log already served on port 80 (http://compute.local/logs/agent-tools)."
    else
      warn "port-80 agent-logs route MISSING (check-only; the Caddyfile route is not live)."
      return 1
    fi
    if webui_logs_up; then
      log "webui log already served on port 80 (http://compute.local/logs/webui)."
    else
      warn "port-80 webui-log route MISSING (check-only; the Caddyfile route or helper is not live)."
      return 1
    fi
    if docs_up; then
      log "docs site already served on port 80 (http://compute.local/docs/)."
    else
      warn "port-80 docs route MISSING (check-only; the Caddyfile route is not live)."
      return 1
    fi
    if readme_up; then
      log "README already served on port 80 (http://compute.local/docs/README.md)."
    else
      warn "port-80 README route MISSING (check-only; the Caddyfile route is not live)."
      return 1
    fi
    if viewer_up; then
      log "README viewer already served on port 80 (http://compute.local/docs/readme.html)."
    else
      warn "port-80 README viewer MISSING (check-only; site/readme.html not served)."
      return 1
    fi
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would run: brew install caddy; install Caddyfile; brew services start caddy (restart if the Caddyfile changed)"
    return 0
  fi
  [[ -f "$ROOT_DIR/configs/Caddyfile" ]] || { warn "Caddy template missing: $ROOT_DIR/configs/Caddyfile"; return 1; }
  if ! command -v caddy >/dev/null 2>&1; then
    log "Installing caddy..."
    brew install caddy || { warn "brew install caddy failed."; return 1; }
  fi
  local dest caddyfile_updated=0 rendered
  dest="$(caddy_caddyfile)"
  rendered="$(mktemp)" || { warn "mktemp failed."; return 1; }
  sed "s|__ROOT__|$ROOT_DIR|g" "$ROOT_DIR/configs/Caddyfile" > "$rendered"
  if [[ ! -f "$dest" ]] || ! cmp -s "$rendered" "$dest"; then
    log "installing Caddyfile to $dest..."
    cp "$rendered" "$dest" || { warn "cannot write $dest."; rm -f "$rendered"; return 1; }
    caddyfile_updated=1
  else
    log "Caddyfile already installed."
  fi
  rm -f "$rendered"
  caddy validate --config "$dest" --adapter caddyfile >/dev/null 2>&1 \
    || { warn "Caddyfile invalid — see: caddy validate --config $dest --adapter caddyfile"; return 1; }
  if ! webui_root_up; then
    log "starting caddy (port 80 -> WebUI + /ollama/* + /logs/*)..."
    brew services start caddy >/dev/null 2>&1 \
      || { warn "could not start caddy — try in your own Terminal: brew services start caddy"; return 1; }
  elif [[ "$caddyfile_updated" -eq 1 ]] || ! ollama_root_up || ! ollama_logs_up \
      || ! caddy_logs_up || ! agent_logs_up || ! webui_logs_up \
      || ! docs_up || ! readme_up; then
    log "Caddyfile changed or a route not live — restarting caddy..."
    brew services restart caddy >/dev/null 2>&1 \
      || { warn "could not restart caddy — try in your own Terminal: brew services restart caddy"; return 1; }
  else
    log "caddy already running with the current Caddyfile."
    return 0
  fi
  local i
  for i in $(seq 1 10); do
    if webui_root_up && ollama_root_up && ollama_logs_up \
        && caddy_logs_up && agent_logs_up && webui_logs_up \
        && docs_up && readme_up; then
      log "port 80 now serves WebUI + ollama + logs + docs."
      return 0
    fi
    sleep 1
  done
  warn "caddy up but :80 not serving everything — see: brew services list; lsof -iTCP:80"
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
  local fail=0 ip name
  ip="$(lan_ip)"
  name="$(lan_name)"
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
  if curl -sf --max-time 5 "http://$ip/health" >/dev/null 2>&1; then
    log "web UI (no port) reachable via LAN: http://$ip"
  elif webui_root_up; then
    log "web UI on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "web UI NOT on port 80 — use http://$ip:3000 until the Caddy proxy runs."
    fail=1
  fi
  if version_match "http://$ip/ollama/api/version"; then
    log "ollama (no port) reachable via LAN: http://$ip/ollama/api"
  elif ollama_root_up; then
    log "ollama route on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "ollama NOT on port 80 — use http://$ip:11434 until the Caddy route runs."
    fail=1
  fi
  if ollama_logs_match "http://$ip/logs/ollama"; then
    log "ollama logs reachable via LAN: http://$ip/logs/ollama"
  elif ollama_logs_up; then
    log "ollama logs on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "ollama logs NOT on port 80 — see the file directly: tail -f /opt/homebrew/var/log/ollama.log"
    fail=1
  fi
  if caddy_logs_match "http://$ip/logs/caddy"; then
    log "caddy log reachable via LAN: http://$ip/logs/caddy"
  elif caddy_logs_up; then
    log "caddy log on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "caddy log NOT on port 80 — see the file directly: tail -f /opt/homebrew/var/log/caddy.log"
    fail=1
  fi
  if agent_logs_match "http://$ip/logs/agent-tools"; then
    log "agent-tools log reachable via LAN: http://$ip/logs/agent-tools"
  elif agent_logs_up; then
    log "agent-tools log on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "agent-tools log NOT on port 80 — see the file directly: tail -f /tmp/agent-tools-mcp.log"
    fail=1
  fi
  if webui_match "http://$ip/logs/webui?tail=20"; then
    log "webui log reachable via LAN: http://$ip/logs/webui"
  elif webui_logs_up; then
    log "webui log on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "webui log NOT on port 80 — is the helper running? (tail /tmp/webui-logs.log)"
    fail=1
  fi
  # Log responses must never be cached (a stale SPA entry once poisoned
  # browsers for days). Route property, so one IP-based check covers it.
  local hdr_fail=0 htmp u
  htmp="$(mktemp)" || hdr_fail=1
  for u in "http://$ip/logs/ollama" "http://$ip/logs/caddy" "http://$ip/logs/agent-tools" "http://$ip/logs/webui?tail=5"; do
    if curl -sI --max-time 5 -o "$htmp" "$u" 2>/dev/null \
       && grep -qi '^cache-control: *no-store' "$htmp"; then
      :
    else
      hdr_fail=1
    fi
  done
  [[ -n "$htmp" ]] && rm -f "$htmp"
  if [[ "$hdr_fail" -eq 0 ]]; then
    log "log endpoints send Cache-Control: no-store."
  else
    warn "log responses cacheable — browsers may show stale logs; re-run to install the current Caddyfile."
    fail=1
  fi
  if docs_match "http://$ip/docs/"; then
    log "docs site reachable via LAN: http://$ip/docs/"
  elif docs_up; then
    log "docs site on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "docs site NOT on port 80 — files live in $ROOT_DIR/site/ until the Caddy route runs."
    fail=1
  fi
  if readme_match "http://$ip/docs/README.md"; then
    log "README reachable via LAN: http://$ip/docs/README.md"
  elif readme_up; then
    log "README on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "README NOT on port 80 — read the file directly: $ROOT_DIR/README.md"
    fail=1
  fi
  if viewer_match "http://$ip/docs/readme.html"; then
    log "README viewer reachable via LAN: http://$ip/docs/readme.html"
  elif viewer_up; then
    log "README viewer on port 80 locally (this shell can't probe LAN IPs — confirm from another machine)."
  else
    warn "README viewer NOT on port 80 — file lives at $ROOT_DIR/site/readme.html."
    fail=1
  fi
  if [[ -n "$name" ]]; then
    if curl -sf --max-time 5 "http://$name:11434/api/version" >/dev/null 2>&1; then
      log "ollama reachable via name: http://$name:11434"
    else
      warn "ollama NOT reachable via $name (mDNS?) — IP http://$ip:11434 is the fallback."
      fail=1
    fi
    if curl -sf --max-time 5 "http://$name:3000/health" >/dev/null 2>&1; then
      log "open-webui reachable via name: http://$name:3000"
    else
      warn "open-webui NOT reachable via $name (mDNS?) — IP http://$ip:3000 is the fallback."
      fail=1
    fi
    if curl -sf --max-time 5 "http://$name/health" >/dev/null 2>&1; then
      log "web UI (no port) reachable via name: http://$name"
    else
      warn "web UI NOT on port 80 via $name — use http://$name:3000 until the Caddy proxy runs."
      fail=1
    fi
    if version_match "http://$name/ollama/api/version"; then
      log "ollama (no port) reachable via name: http://$name/ollama/api"
    else
      warn "ollama NOT on port 80 via $name — use http://$name:11434 until the Caddy route runs."
      fail=1
    fi
    if ollama_logs_match "http://$name/logs/ollama"; then
      log "ollama logs reachable via name: http://$name/logs/ollama"
    else
      warn "ollama logs NOT on port 80 via $name — see the file directly: tail -f /opt/homebrew/var/log/ollama.log"
      fail=1
    fi
    if caddy_logs_match "http://$name/logs/caddy"; then
      log "caddy log reachable via name: http://$name/logs/caddy"
    else
      warn "caddy log NOT on port 80 via $name — see the file directly: tail -f /opt/homebrew/var/log/caddy.log"
      fail=1
    fi
    if agent_logs_match "http://$name/logs/agent-tools"; then
      log "agent-tools log reachable via name: http://$name/logs/agent-tools"
    else
      warn "agent-tools log NOT on port 80 via $name — see the file directly: tail -f /tmp/agent-tools-mcp.log"
      fail=1
    fi
    if webui_match "http://$name/logs/webui?tail=20"; then
      log "webui log reachable via name: http://$name/logs/webui"
    else
      warn "webui log NOT on port 80 via $name — is the helper running? (tail /tmp/webui-logs.log)"
      fail=1
    fi
    if docs_match "http://$name/docs/"; then
      log "docs site reachable via name: http://$name/docs/"
    else
      warn "docs site NOT on port 80 via $name — files live in $ROOT_DIR/site/ until the Caddy route runs."
      fail=1
    fi
    if readme_match "http://$name/docs/README.md"; then
      log "README reachable via name: http://$name/docs/README.md"
    else
      warn "README NOT on port 80 via $name — read the file directly: $ROOT_DIR/README.md"
      fail=1
    fi
    if viewer_match "http://$name/docs/readme.html"; then
      log "README viewer reachable via name: http://$name/docs/readme.html"
    else
      warn "README viewer NOT on port 80 via $name — file lives at $ROOT_DIR/site/readme.html."
      fail=1
    fi
  else
    warn "no mDNS name (Bonjour unavailable) — use the LAN IP above."
    fail=1
  fi
  firewall_note
  if [[ "$fail" -eq 0 ]]; then
    log "Phase 5 OK: LAN access ready."
    log "Other machines: Ollama http://$ip:11434 | WebUI http://$ip:3000 (or no-port http://$ip)"
    log "No-port Ollama API: http://$ip/ollama/api (OpenAI-compat baseURL http://$ip/ollama/v1)"
    log "Log endpoints (debug): http://$ip/logs/ollama http://$ip/logs/caddy http://$ip/logs/agent-tools http://$ip/logs/webui"
    [[ -n "$name" ]] && log "Stable log names: http://$name/logs/ollama http://$name/logs/caddy http://$name/logs/agent-tools http://$name/logs/webui"
    log "Docs site: http://$ip/docs/ (logs viewer: http://$ip/docs/logs.html, README: http://$ip/docs/readme.html)"
    local name
    name="$(lan_name)"
    [[ -n "$name" ]] && log "Stable names (survive DHCP changes): Ollama http://$name:11434 | WebUI http://$name:3000 | No-port API http://$name/ollama/api"
    log "opencode elsewhere: provider baseURL http://$ip:11434/v1 (or no-port http://$ip/ollama/v1; same LAN only)."
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
  unproxy_lan
  preflight
  local rc=0
  ensure_hostname || rc=1
  ensure_ollama_lan || rc=1
  ensure_webui_lan || rc=1
  ensure_webui_logs || rc=1
  ensure_webui_root || rc=1
  # Verification runs at the end of every phase, even on partial failure.
  verify || rc=1
  [[ "$DRY_RUN" -eq 1 ]] && log "Done (dry run) — nothing changed."
  exit "$rc"
}

main "$@"
