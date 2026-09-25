#!/usr/bin/env bash
# eval.sh — Step 1 of follow-up-plan1.md: model x demo eval matrix.
# For each model in EVAL_MODELS and demo in EVAL_DEMOS: reset the demo
# deliverables, run opencode non-interactively with pre-allowed file/shell
# permissions, grade with the demo's own checker, record PASS/FAIL + wall
# time + tokens. Results append to eval-results-<date>.md; raw logs land
# under eval-logs/<date>/<model>/<demo>/.
# Re-runnable: pre-existing deliverables are backed up at start and restored
# at exit (even on interrupt), so runs never contaminate each other or you.
# All outputs live under eval-results/ (gitignored).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATE="$(date +%Y-%m-%d)"
RESULTS="${EVAL_RESULTS:-$ROOT_DIR/eval-results/eval-results-$DATE.md}"
LOGDIR="${EVAL_LOGDIR:-$ROOT_DIR/eval-results/logs/$DATE}"
MODELS="${EVAL_MODELS:-muse-glimmer:30b-mlx gpt-oss:120b qwen3-coder:30b}"
DEMOS="${EVAL_DEMOS:-01 02 03}"
TIMEOUT="${EVAL_TIMEOUT:-1200}"
VENV_PY="$ROOT_DIR/.venv/bin/python"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

DRY_RUN=0
CHECK_ONLY=0
BACKUP_DIR=""

log() { printf '[eval] %s\n' "$*"; }
warn() { printf '[eval] WARN: %s\n' "$*" >&2; }
die() { printf '[eval] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./eval.sh [options]

Step 1 of follow-up-plan1.md: run every demo with every model, grade it.

Options:
  --dry-run    Print the run matrix, run nothing
  --check-only Verify prerequisites, run nothing
  -h, --help   Show this help

Env:
  EVAL_MODELS  Space-separated Ollama models (default: glimmer, gpt-oss, qwen3)
  EVAL_DEMOS   Space-separated demos from {01 02 03} (default: all)
  EVAL_TIMEOUT Seconds per opencode run (default: 1200)
  EVAL_RESULTS Results file (default: eval-results/eval-results-<date>.md)
  EVAL_LOGDIR  Raw-log directory (default: eval-results/logs/<date>/)

Examples:
  EVAL_MODELS="muse-glimmer:30b-mlx" EVAL_DEMOS="02" ./eval.sh
  ./eval.sh --dry-run
EOF
}

preflight() {
  command -v opencode >/dev/null 2>&1 || die "opencode not found."
  [[ -n "$TIMEOUT_BIN" ]] || die "neither timeout nor gtimeout found."
  [[ -x "$VENV_PY" ]] || die "project .venv missing — run phase1.sh first."
  curl -sf --max-time 5 localhost:11434/api/tags >/dev/null 2>&1 \
    || die "ollama server not reachable."
  local m
  for m in $MODELS; do
    ollama show "$m" >/dev/null 2>&1 || die "model missing: $m (ollama pull it first)."
  done
  if [[ "$DEMOS" == *"03"* ]]; then
    curl -sf --max-time 5 localhost:6333/ >/dev/null 2>&1 \
      || die "demo 03 needs Qdrant (:6333) — run phase3.sh first."
  fi
  if [[ "$DEMOS" == *"02"* ]]; then
    curl -sf --max-time 8 -o /dev/null https://example.com 2>/dev/null \
      || die "demo 02 needs internet (https://example.com unreachable)."
  fi
  (cd "$ROOT_DIR" && git rev-parse --is-inside-work-tree >/dev/null 2>&1) \
    || die "not a git checkout (stub restore needs git)."
  [[ -f "$ROOT_DIR/configs/opencode-eval-permissions.json" ]] \
    || die "configs/opencode-eval-permissions.json missing."
  log "preflight OK (models: $MODELS; demos: $DEMOS; timeout: ${TIMEOUT}s)."
}

# Files the harness mutates: deliverables + temporary permission grants.
MUTABLE="demo/01-coding-bob/bob.py
demo/01-coding-bob/opencode.json
demo/02-internet-research/answers.md
demo/02-internet-research/opencode.json
demo/03-text-alice/answers.md
opencode.json"

backup_user_files() {
  BACKUP_DIR="$(mktemp -d /tmp/eval-backup.XXXXXX)"
  local f
  while IFS= read -r f; do
    if [[ -e "$ROOT_DIR/$f" ]]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$f")"
      cp -p "$ROOT_DIR/$f" "$BACKUP_DIR/$f"
    else
      mkdir -p "$BACKUP_DIR/$(dirname "$f")"
      : > "$BACKUP_DIR/$f.absent"
    fi
  done <<< "$MUTABLE"
}

restore_user_files() {
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 0
  (cd "$BACKUP_DIR" && find . -name '*.absent') | while IFS= read -r a; do
    local t="${a#./}"
    rm -f "$ROOT_DIR/${t%.absent}"
  done
  (cd "$BACKUP_DIR" && find . -type f ! -name '*.absent') | while IFS= read -r f; do
    f="${f#./}"
    mkdir -p "$ROOT_DIR/$(dirname "$f")"
    cp -p "$BACKUP_DIR/$f" "$ROOT_DIR/$f"
  done
  rm -rf "$BACKUP_DIR"
  BACKUP_DIR=""
}

# Pristine start for one demo run: committed stub + no deliverable.
reset_demo() {
  case "$1" in
    01) (cd "$ROOT_DIR" && git show "HEAD:demo/01-coding-bob/bob.py" > demo/01-coding-bob/bob.py) ;;
    02) rm -f "$ROOT_DIR/demo/02-internet-research/answers.md" ;;
    03) rm -f "$ROOT_DIR/demo/03-text-alice/answers.md" ;;
  esac
}

demo_dir() {
  case "$1" in
    01) echo "$ROOT_DIR/demo/01-coding-bob" ;;
    02) echo "$ROOT_DIR/demo/02-internet-research" ;;
    03) echo "$ROOT_DIR" ;; # TASK.md paths are repo-root-relative
  esac
}

demo_prompt() {
  case "$1" in
    01) echo "implement bob.py so all tests pass. Verify with ../../.venv/bin/python -m pytest bob_test.py -q and iterate until green." ;;
    02) echo "complete the TASK in TASK.md" ;;
    03) echo "complete the TASK in demo/03-text-alice/TASK.md" ;;
  esac
}

grade_demo() {
  case "$1" in
    01) (cd "$ROOT_DIR/demo/01-coding-bob" && "$VENV_PY" -m pytest bob_test.py -q >/dev/null 2>&1) ;;
    02) (cd "$ROOT_DIR/demo/02-internet-research" && python3 check.py >/dev/null 2>&1) ;;
    03) (cd "$ROOT_DIR/demo/03-text-alice" && python3 check.py >/dev/null 2>&1) ;;
  esac
}

# Token tally from `opencode run --format json` (one event per line):
# sum part.tokens.input/output across step_finish events. Prints
# "in=X out=Y", or "n/a" when the stream carries no token fields.
tally_tokens() {
  "$VENV_PY" - "$1" <<'EOF' 2>/dev/null || echo "n/a"
import json, sys
tin = tout = 0
seen = False
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") != "step_finish":
        continue
    tok = (ev.get("part") or {}).get("tokens") or {}
    if isinstance(tok.get("input"), int) or isinstance(tok.get("output"), int):
        seen = True
        tin += tok.get("input") or 0
        tout += tok.get("output") or 0
print(f"in={tin} out={tout}" if seen else "n/a")
EOF
}

run_one() {
  local model="$1" demo="$2"
  local dir runlog rundir result elapsed tokens note=""
  rundir="$LOGDIR/$model/$demo"
  mkdir -p "$rundir"
  runlog="$rundir/run.log"
  reset_demo "$demo"
  dir="$(demo_dir "$demo")"
  cp "$ROOT_DIR/configs/opencode-eval-permissions.json" "$dir/opencode.json"
  log "run: $model demo $demo (timeout ${TIMEOUT}s)..."
  local start=$SECONDS
  # shellcheck disable=SC2086
  if "$TIMEOUT_BIN" "$TIMEOUT" opencode run --dir "$dir" -m "ollama/$model" \
      --format json "$(demo_prompt "$demo")" >"$runlog" 2>&1; then
    : # exit status recorded below via grade
  else
    local rc=$?
    [[ $rc -eq 124 ]] && note="opencode timeout after ${TIMEOUT}s" || note="opencode exit $rc"
  fi
  elapsed=$((SECONDS - start))
  rm -f "$dir/opencode.json"
  if grade_demo "$demo"; then
    result="PASS"
  else
    result="FAIL"
  fi
  tokens="$(tally_tokens "$runlog")"
  printf '| %s | %s | %s | %ss | %s | %s |\n' "$model" "$demo" "$result" "$elapsed" "$tokens" "$note" >> "$RESULTS"
  log "run: $model demo $demo -> $result (${elapsed}s, $tokens)${note:+ [$note]}"
  [[ "$result" == "PASS" ]]
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
  if [[ "$CHECK_ONLY" -eq 1 ]]; then log "check-only OK."; exit 0; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    local m d
    for m in $MODELS; do for d in $DEMOS; do echo "would run: $m demo $d"; done; done
    exit 0
  fi
  mkdir -p "$(dirname "$RESULTS")" "$LOGDIR"
  if [[ ! -f "$RESULTS" ]]; then
    {
      echo "# Eval results — $DATE"
      echo
      echo "Models: $MODELS"
      echo "Demos: $DEMOS (01=coding-bob, 02=internet-research, 03=text-alice)"
      echo "Timeout: ${TIMEOUT}s per run. Logs: \`$LOGDIR/<model>/<demo>/run.log\`"
      echo
      echo "| model | demo | result | time | tokens | notes |"
      echo "|---|---|---|---|---|---|"
    } > "$RESULTS"
  fi
  backup_user_files
  trap restore_user_files EXIT
  local m d rc=0
  for m in $MODELS; do
    for d in $DEMOS; do
      run_one "$m" "$d" || rc=1
    done
  done
  log "done: results in $RESULTS"
  exit "$rc"
}

main "$@"
