#!/usr/bin/env bash
# Runs the Rust (cberner crate) and Bend benchmarks over K in {100,1000,4000,10000} x T in {16,1024}.
# Usage: [PIN=<cpu>] [THREADS="1 12"] [N=1000] tools/bench/run.sh [reps=3]      PIN pins the 1-thread Bend runs and the (single-threaded)
# Rust runs to one core (use a big core, e.g. PIN=11 on the 12-core cix box); runs with more threads are never pinned.   Output: build/bench_results.txt (one RUST/BEND line per run) and a min-of-reps table.
# Needs: cargo, bend, a system clang first in PATH (see CLAUDE.md).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$HOME/.cargo/bin:$PATH" BEND_NO_TELEMETRY=1
REPS=${1:-3}
N=${N:-1000}
THREADS=${THREADS:-"1 12"}
mkdir -p build
(cd tools/bench_rs && cargo build --release -q 2>/dev/null)
bend tools/bench/bench.bend -o build/bench >/dev/null
OUT=build/bench_results.txt
: > "$OUT"
for k in 100 1000 4000 10000; do
  for t in 16 1024; do
    for r in $(seq "$REPS"); do
      ${PIN:+taskset -c $PIN} tools/bench_rs/target/release/bench_rs "$k" "$t" "$N" | tee -a "$OUT"
      for th in $THREADS; do
        if [ "$th" = 1 ]; then pin=${PIN:+taskset -c $PIN}; else pin=; fi
        $pin ./build/bench --threads "$th" -- "$k" "$t" "$N" | grep '^BEND' | tee -a "$OUT"
      done
    done
  done
done
python3 - "$OUT" <<'PY'
import sys, re, collections
best = collections.defaultdict(lambda: collections.defaultdict(lambda: 1e18))
for line in open(sys.argv[1]):
    kv = dict(p.split('=') for p in line.split()[1:])
    who = line.split()[0] + (kv.get('threads', '') and '/' + kv['threads'])
    key = (int(kv['K']), int(kv['T']))
    for m in ('setup_ms', 'setup_cold_ms', 'setup_warm_ms', 'repair_ms', 'decode_ms'):
        if m in kv:
            best[key + (who,)][m] = min(best[key + (who,)][m], float(kv[m]))
print("\nmin over reps (ms):")
for k in sorted(best):
    print(k, dict(best[k]))
PY
