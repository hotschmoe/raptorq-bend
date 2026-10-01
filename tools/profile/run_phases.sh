#!/bin/bash
# usage: tools/profile/run_phases.sh build/profile/phases "1000 4000" "16 1024" [reps] [cpu]
# Prints cumulative ms per stage (min of reps, 1 thread, pinned to one core; the harness subtracts a second row build):
#   s1 init (normalise rows + index) s2 +phase-1 loop s3 +log replay s4 +leftover/dense-row correction s5 +tail Gauss-Jordan s6 +phase 3 (full solve)
BIN=${1:-build/profile/phases}; KS=${2:-"1000 4000"}; TS=${3:-"16 1024"}; R=${4:-3}; CPU=${5:-10}
for K in $KS; do for T in $TS; do
  line=""; rows=999999
  for S in 1 2 3 4 5 6; do
    best=999999999
    for r in $(seq $R); do
      out=$(taskset -c $CPU $BIN --threads 1 -- $K $T $S | grep PHASES)
      ms=$(echo "$out" | sed -n 's/.*cut_ms=\([0-9]*\) cut_incl.*/\1/p')
      rm=$(echo "$out" | sed -n 's/.*rows_ms=\([0-9]*\) .*/\1/p')
      [ "$ms" -lt "$best" ] && best=$ms
      [ "$rm" -lt "$rows" ] && rows=$rm
    done
    line="$line s$S=$best"
  done
  echo "K=$K T=$T rows=$rows :$line"
done; done
