#!/usr/bin/env bash
# benchmark.sh — STANDALONE MLX vs GGUF shootout (not part of setup).
# Compares Ollama (GGUF) against Apple MLX on fixed prompts with the same
# model class, reporting tokens/sec + wall time + a verdict per prompt.
# First MLX run downloads ~19GB of 4-bit weights from Hugging Face.
# Results go to a timestamped Markdown file; re-runs create new files.
# Portable bash (no associative arrays: macOS ships bash 3.2).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$ROOT_DIR/.venv/bin/python"
OLLAMA_URL="http://127.0.0.1:11434"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:32b}"
MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen2.5-Coder-32B-Instruct-4bit}"
MAX_TOKENS=200

DRY_RUN=0
QUICK=0

log() { printf '[benchmark] %s\n' "$*"; }
warn() { printf '[benchmark] WARN: %s\n' "$*" >&2; }
die() { printf '[benchmark] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./benchmark.sh [options]

Standalone only — not wired into local-intelligence-setup.sh.

Options:
  --dry-run        Show the run matrix, download/run nothing
  --quick          One prompt, 64 tokens (smoke of the harness)
  --max-tokens=N   Generation cap per prompt (default 200)
  -h, --help       Show this help

Env:
  OLLAMA_MODEL  GGUF contender (default qwen2.5-coder:32b)
  MLX_MODEL     MLX contender (default mlx-community/Qwen2.5-Coder-32B-Instruct-4bit)
EOF
}

PROMPTS=(
  "Write a python function that returns the nth Fibonacci number. Reply with code only."
  "Explain in two sentences why quicksort is O(n log n) on average."
  "A bat and ball cost \$1.10, the bat costs \$1 more than the ball. How much is the ball? Answer briefly."
)

preflight() {
  [[ -x "$VENV_PY" ]] || die "project .venv missing — run ./phase1.sh first."
  "$VENV_PY" -c "import mlx_lm" 2>/dev/null || die "mlx_lm not in .venv — run ./phase1.sh first."
  curl -sf --max-time 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 \
    || die "ollama server not reachable — run ./phase1.sh first."
  ollama show "$OLLAMA_MODEL" >/dev/null 2>&1 \
    || die "ollama model $OLLAMA_MODEL missing — run ./phase2.sh first."
  log "preflight OK (ollama+$OLLAMA_MODEL, mlx_lm; MLX weights download on first use)."
}

# run_ollama <prompt> <outfile> → prints "prompt_tps gen_tps wall_s chars"
run_ollama() {
  local prompt="$1" out="$2" start end
  start="$(date +%s)"
  OLLAMA_URL="$OLLAMA_URL" OLLAMA_MODEL="$OLLAMA_MODEL" MAX_TOKENS="$MAX_TOKENS" \
    PROMPT="$prompt" "$VENV_PY" - > "$out" <<'EOF'
import json, os, urllib.request
body = json.dumps({"model": os.environ["OLLAMA_MODEL"], "prompt": os.environ["PROMPT"],
                   "stream": False,
                   "options": {"num_predict": int(os.environ["MAX_TOKENS"]), "temperature": 0}})
req = urllib.request.Request(os.environ["OLLAMA_URL"] + "/api/generate",
                             data=body.encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=600) as r:
    print(r.read().decode())
EOF
  end="$(date +%s)"
  "$VENV_PY" - "$out" "$((end - start))" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
wall = float(sys.argv[2]) or 1.0
pe, pd = d.get("prompt_eval_count", 0), d.get("prompt_eval_duration", 0) or 1
ec, ed = d.get("eval_count", 0), d.get("eval_duration", 0) or 1
print("%.1f %.1f %.0f %d" % (pe / (pd / 1e9), ec / (ed / 1e9), wall, len(d.get("response", ""))))
EOF
}

# run_mlx <prompt> <outfile> → prints "prompt_tps gen_tps wall_s chars"
run_mlx() {
  local prompt="$1" out="$2" start end
  start="$(date +%s)"
  "$ROOT_DIR/.venv/bin/mlx_lm.generate" --model "$MLX_MODEL" --temp 0 --seed 0 \
    --max-tokens "$MAX_TOKENS" --prompt "$prompt" > "$out" 2>&1
  end="$(date +%s)"
  "$VENV_PY" - "$out" "$((end - start))" <<'EOF'
import re, sys
raw = open(sys.argv[1]).read()
wall = float(sys.argv[2]) or 1.0
def tps(label):
    m = re.search(label + r".*?([\d.]+)\s*(?:tokens-per-sec|tokens?/s)", raw)
    return m.group(1) if m else "n/a"
parts = raw.split("==========")
# mlx_lm prints completion first, then the separator, then the stats block.
body = parts[0] if len(parts) > 1 else raw
text = body.strip()
if "No text generated" in raw:
    text = ""
print("%s %s %.0f %d" % (tps("[Pp]rompt"), tps("[Gg]eneration"), wall, len(text)))
EOF
}

main() {
  local prompts=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --quick) QUICK=1; MAX_TOKENS=64 ;;
      --max-tokens=*) MAX_TOKENS="${arg#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $arg (try --help)" ;;
    esac
  done
  prompts=("${PROMPTS[@]}")
  if [[ "$QUICK" -eq 1 ]]; then prompts=("${PROMPTS[0]}"); fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN — matrix (no downloads, no runs):"
    log "  backends: ollama/$OLLAMA_MODEL mlx/$MLX_MODEL | max_tokens=$MAX_TOKENS"
    local i
    for i in "${!prompts[@]}"; do
      log "  prompt $((i + 1)): ${prompts[$i]:0:70}..."
    done
    return 0
  fi
  preflight
  local tmp result_file ts
  tmp="$(mktemp -d /tmp/bench.XXXXXX)"
  ts="$(date +%Y%m%d-%H%M)"
  result_file="$ROOT_DIR/benchmark-results-$ts.md"
  # Indexed results: R_OLLAMA[i], R_MLX[i] (bash 3.2 has no assoc arrays).
  local R_OLLAMA=() R_MLX=()
  local b i r
  for b in ollama mlx; do
    log "warmup: $b (discarded)..."
    if [[ "$b" == "ollama" ]]; then
      run_ollama "Say OK." "$tmp/warm-$b.json" >/dev/null 2>&1 || warn "warmup failed: $b"
    else
      run_mlx "Say OK." "$tmp/warm-$b.txt" >/dev/null 2>&1 || warn "warmup failed: $b (weights download on first use)"
    fi
    for i in "${!prompts[@]}"; do
      log "run: $b prompt $((i + 1))/${#prompts[@]} (max_tokens=$MAX_TOKENS)..."
      if [[ "$b" == "ollama" ]]; then
        r="$(run_ollama "${prompts[$i]}" "$tmp/$b-$i.json" 2>/dev/null || echo "n/a n/a n/a 0")"
        R_OLLAMA[$i]="$r"
      else
        r="$(run_mlx "${prompts[$i]}" "$tmp/$b-$i.txt" 2>/dev/null || echo "n/a n/a n/a 0")"
        R_MLX[$i]="$r"
      fi
      log "  -> $r"
    done
  done
  local fail=0 ptps gtps wall chars og mg winner
  {
    echo "# Benchmark $ts"
    echo
    echo "ollama=$OLLAMA_MODEL mlx=$MLX_MODEL max_tokens=$MAX_TOKENS"
    echo
    echo "| prompt | backend | prompt tok/s | gen tok/s | wall s | chars |"
    echo "|---|---|---|---|---|---|"
    for i in "${!prompts[@]}"; do
      for b in ollama mlx; do
        if [[ "$b" == "ollama" ]]; then r="${R_OLLAMA[$i]}"; else r="${R_MLX[$i]}"; fi
        read -r ptps gtps wall chars <<< "$r"
        echo "| $((i + 1)) | $b | $ptps | $gtps | $wall | $chars |"
        if [[ "$gtps" == "n/a" || "$chars" == "0" ]]; then fail=1; fi
      done
      og="$(echo "${R_OLLAMA[$i]}" | awk '{print $2}')"
      mg="$(echo "${R_MLX[$i]}" | awk '{print $2}')"
      winner="tie"
      if [[ "$og" != "n/a" && "$mg" != "n/a" ]]; then
        winner="$(awk -v o="$og" -v m="$mg" 'BEGIN{print (m>o)?"mlx":((o>m)?"ollama":"tie")}')"
      fi
      echo
      echo "prompt $((i + 1)) fastest (gen tok/s): **$winner**"
      echo
    done
    if [[ "$fail" -eq 1 ]]; then
      echo "INCOMPLETE: some runs produced no data — see warnings above."
    else
      echo "All runs produced data."
    fi
  } > "$result_file"
  cat "$result_file"
  rm -rf "$tmp"
  log "results saved: $result_file"
  [[ "$fail" -eq 0 ]] || return 1
}

main "$@"
