#!/usr/bin/env bash
# power-settings.sh — unattended-server power policy for local-intelligence.
# Must run with sudo: `sudo ./power-settings.sh` (pmset writes system policy).
# Goal: machine never sleeps (services stay up) while idling cheaply:
# display + disks spin down, CPU throttles itself, fans stay automatic.
# Safe on this desktop Mac (no battery to wear); just pair with a screen lock.
set -euo pipefail

# Desired charger-profile values: name=value pairs.
WANT="sleep 0 displaysleep 10 disksleep 10 autorestart 1"
CHECK_ONLY=0

log() { printf '[power] %s\n' "$*"; }
warn() { printf '[power] WARN: %s\n' "$*" >&2; }
die() { printf '[power] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo ./power-settings.sh [options]

Options:
  --check-only  Show current vs desired policy, change nothing
  -h, --help    Show this help

Applies (charger profile): sleep 0, displaysleep 10, disksleep 10, autorestart 1.
Also sensible: System Settings > Lock Screen > require password (unattended box),
and Docker Desktop > Start at login (Qdrant/WebUI after reboots).
EOF
}

current() {
  pmset -g | awk -v k="$1" '$1==k {print $2}'
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --check-only) CHECK_ONLY=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $arg (try --help)" ;;
    esac
  done
  if [[ "$CHECK_ONLY" -eq 0 && "$(id -u)" -ne 0 ]]; then
    die "re-run with sudo: sudo ./power-settings.sh"
  fi
  log "current: sleep=$(current sleep) displaysleep=$(current displaysleep) disksleep=$(current disksleep) autorestart=$(current autorestart)"
  local rc=0 pair k v
  for pair in sleep:0 displaysleep:10 disksleep:10 autorestart:1; do
    k="${pair%%:*}"; v="${pair##*:}"
    if [[ "$(current "$k")" == "$v" ]]; then
      log "$k=$v OK"
    elif [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "$k is $(current "$k") (check-only; would set $v)"
      rc=1
    else
      pmset -c "$k" "$v" && log "$k -> $v applied"
    fi
  done
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    [[ "$rc" -eq 0 ]] && log "power policy already correct."
    exit "$rc"
  fi
  log "verified: sleep=$(current sleep) displaysleep=$(current displaysleep) disksleep=$(current disksleep) autorestart=$(current autorestart)"
  log "Done. Pair with a screen lock (System Settings > Lock Screen) for unattended use."
}

main "$@"
