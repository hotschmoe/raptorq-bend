#!/usr/bin/env bash
# The scaling-lab table of docs/scaling.md.   Usage: tools/scaling/run_all.sh [reps=5] > build/scaling/results.txt
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1
mkdir -p build/scaling
bend tools/scaling/lab.bend -o build/scaling/lab >/dev/null
R=${1:-5}
S="python3 tools/scaling/sweep.py build/scaling/lab $R 1,2,4,8,12"
echo "== A. balanced fork tree, leaves allocate their own array (mode 0): leaf ~1us, 10us, 100us, 1ms, 10ms (total ~0.5-0.8 s of work)"
$S "0 19 10 1 1" "0 16 10 10 1" "0 13 12 25 1" "0 10 14 60 1" "0 6 14 600 1"
echo "== B. depth / granularity at 100us leaves"
$S "0 3 12 3000 1" "0 4 12 1500 1" "0 5 12 750 1" "0 7 12 200 1" "0 9 12 60 1" "0 13 12 25 1"
echo "== C. forks from sequential code (mode 1: n rounds of an 8-leaf tree) vs one wrapping region (mode 2), 85us / 10us / 4us leaves"
$S "1 3 12 25 500" "2 3 12 25 500" "1 3 10 10 5000" "2 3 10 10 5000" "1 3 8 4 20000" "2 3 8 4 20000"
echo "== D. tail vs non-tail leaf recursion (modes 3, 4) and a fork-free def next to a fork (9, 10, 11; D=0: nothing to parallelise, so the speedup column is the per-thread-count slowdown)"
$S "3 13 8 25 1" "4 13 8 25 1" "3 0 16 800 1" "4 0 16 800 1" "9 0 8 20000 1" "10 0 8 20000 1" "11 0 8 20000 1" "7 13 12 25 1"
echo "== E. handing out slices of ONE array: ANode halves (5) vs tree of leaf arrays (6) vs own arrays (0), 100us and 10ms leaves; slice overhead at equal work"
$S "5 13 12 25 1" "6 13 12 25 1" "0 13 12 25 1" "5 6 14 600 1" "6 6 14 600 1" "5 0 18 1000 1" "5 6 12 1000 1" "5 10 8 1000 1" "5 14 4 1000 1" "5 16 2 1000 1" "5 18 0 1000 1"
echo "== F. shared read-only input via Array.fork (mode 12; 2^D leaves of 2^w words, reps symbols each, 2^extra symbols in S)"
$S "12 10 8 8 12" "12 10 8 40 12" "12 10 10 64 10" "12 12 8 40 12" "12 6 12 64 10"
echo "== G. a Data list (plan-shaped) shared by all leaves (13) vs private copies (14)"
$S "13 4 14 300 1" "14 4 14 300 1" "13 3 16 100 1" "14 3 16 100 1"
