#!/usr/bin/env bash
# Runs the Rust (cberner crate) and Bend benchmarks over K in {100,1000,4000,10000} x T in {16,1024}.
# Usage: [PIN=auto|<cpu>] [THREADS="1 8 12"] [N=1000] tools/bench/run.sh [reps=3]
#   1-thread Bend runs and the (single-threaded) Rust runs are pinned to one big (A720) core: PIN=auto (default) picks the least busy big core
#   at the time of every run (tools/scaling/quietcore.sh), PIN=<cpu> fixes it, PIN= disables pinning. Runs with 2..8 threads are confined to the
#   8 big cores (BIG=0,1,6,7,8,9,10,11), runs with more threads are not pinned (the 4 Cortex-A520 are ~3.5x slower: docs/scaling.md).
#   Bend is run in mode 0 (tree API: encoder_auto / symbols_auto / decode_auto) and mode 1 (linear flat API for setup and repair).
# Output: build/bench_results.txt (one RUST/BEND line per run) and a min-of-reps table.   Needs: cargo, bend, a system clang first in PATH (CLAUDE.md).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$HOME/.cargo/bin:$PATH" BEND_NO_TELEMETRY=1
REPS=${1:-3}
N=${N:-1000}
THREADS=${THREADS:-"1 8 12"}
PIN=${PIN-auto}
BIG=${BIG:-0,1,6,7,8,9,10,11}
mkdir -p build
(cd tools/bench_rs && cargo build --release -q 2>/dev/null)
bend tools/bench/bench.bend -o build/bench >/dev/null
OUT=build/bench_results.txt
: > "$OUT"
core() { if [ "$PIN" = auto ]; then bash tools/scaling/quietcore.sh 2>/dev/null; else echo "$PIN"; fi; }
for k in 100 1000 4000 10000; do
  for t in 16 1024; do
    for r in $(seq "$REPS"); do
      if [ -n "$PIN" ]; then taskset -c "$(core)" tools/bench_rs/target/release/bench_rs "$k" "$t" "$N" | tee -a "$OUT"; else tools/bench_rs/target/release/bench_rs "$k" "$t" "$N" | tee -a "$OUT"; fi
      for th in $THREADS; do
        if [ "$th" = 1 ] && [ -n "$PIN" ]; then pin="taskset -c $(core)"; elif [ "$th" -le 8 ] && [ "$th" -gt 1 ]; then pin="taskset -c $BIG"; else pin=; fi
        for mode in 0 1; do
          $pin ./build/bench --threads "$th" -- "$k" "$t" "$N" "$mode" | grep '^BEND' | tee -a "$OUT"
        done
      done
    done
  done
done
python3 tools/bench/table.py "$OUT"
