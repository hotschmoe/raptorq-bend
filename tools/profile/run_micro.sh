#!/bin/bash
# Builds and runs every micro-benchmark of docs/profile.md, min of REPS runs each, pinned to one core (CPU, default 10).
#   tools/profile/run_micro.sh [reps] > tools/profile/results/micro_results.txt   (run from the repo root; B=build dir, default build/profile)
REPS=${1:-5}; CPU=${CPU:-10}; B=${B:-build/profile}; mkdir -p $B
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1
bend tools/profile/mb_vec.bend -o $B/mb_vec >/dev/null
bend tools/profile/mb_arr.bend -o $B/mb_arr >/dev/null
bend tools/profile/mb_gj.bend -o $B/mb_gj_b >/dev/null
bend tools/profile/mb_repair.bend -o $B/mb_repair >/dev/null
bend tools/profile/mb_list.bend -o $B/mb_list >/dev/null
bend tools/profile/mb_arrops.bend -o $B/mb_arrops >/dev/null
bend tools/profile/mb_mulw.bend -o $B/mb_mulw >/dev/null
for M in 4 16; do for K in 0 2; do python3 tools/profile/gen_mb_leaf.py $M $K; bend tools/profile/mb_leaf_${M}_$K.bend -o $B/mb_leaf_${M}_$K >/dev/null; done; done
gcc -O3 -o $B/mb_c tools/profile/mb_c.c; gcc -O3 -fno-tree-vectorize -o $B/mb_c_novec tools/profile/mb_c.c
gcc -O3 -o $B/mb_gj tools/profile/mb_gj.c; gcc -O3 -o $B/mb_list_c tools/profile/mb_list.c
# minms CMD...  -> min over REPS of the "ms=NNN" token of the RESULT line
minms() { local best=999999999 ms; for r in $(seq $REPS); do ms=$(taskset -c $CPU "$@" 2>&1 | grep -a -o "ms=[0-9.]*" | tail -1 | cut -d= -f2 | cut -d. -f1); [ -n "$ms" ] && [ "$ms" -lt "$best" ] && best=$ms; done; echo $best; }
echo "## C baselines (min of 3 internal)"; taskset -c $CPU $B/mb_c; taskset -c $CPU $B/mb_c_novec | grep xor_scalar | sed 's/xor_scalar/xor_bytewise_novec/'
echo "## Bend: tree-of-words Vec (gf256.bend), --threads 1  [ms per 10.24M words: ops*words]"
for W in 256 4; do OPS=$((10240000/W)); for mode in 0 1; do echo "vec words=$W ops=$OPS mode=$mode(0=xor,1=muladd mulw SWAR) ms=$(minms $B/mb_vec --threads 1 -- $W $OPS $mode)"; done; done
echo "## Bend: tree-of-words Vec, --threads 2 / 12 (same binary, same single-threaded work)"
for th in 2 12; do for mode in 0 1; do echo "vec threads=$th words=256 ops=40000 mode=$mode ms=$(minms $B/mb_vec --threads $th -- 256 40000 $mode)"; done; done
echo "## Bend: mulw kernel variants inside the Vec walk (0 SWAR 1 unrolled SWAR 2 bit-sliced hoisted 3 log/exp 4 control xor-only) words=256 ops=40000"
for v in 0 1 2 3 4; do echo "mulw variant=$v ms=$(minms $B/mb_mulw --threads 1 -- 256 40000 $v)"; done
echo "## Bend: wider leaves (M words per leaf), kernels 0=G.mulw 2=bit-sliced hoisted; words=256 ops=40000"
for M in 4 16; do for K in 0 2; do for mode in 0 1; do echo "leaf=$M kernel=$K mode=$mode(0=xor,1=muladd) ms=$(minms $B/mb_leaf_${M}_$K --threads 1 -- 256 40000 $mode)"; done; done; done
echo "## Bend: flat Array<U32> symbols  (0 xor, 1 muladd SWAR, 2 muladd bit-sliced, 3 muladd 64K table)"
for W in 4096 256 4; do OPS=$((10240000/W)); for v in 0 1 2 3; do echo "arr words=$W ops=$OPS variant=$v ms=$(minms $B/mb_arr --threads 1 -- $W $OPS $v)"; done; done
echo "## Bend: flat Array<U32>, --threads 2 / 12 (same single-threaded work)"
for th in 2 12; do for v in 0 3; do echo "arr threads=$th words=256 ops=40000 variant=$v ms=$(minms $B/mb_arr --threads $th -- 256 40000 $v)"; done; done
echo "## dense Gauss-Jordan n x (n+T): C table / C neon / Bend flat arrays"
for cfg in "79 1024" "142 1024" "79 16" "142 16"; do taskset -c $CPU $B/mb_gj $cfg 5; set -- $cfg; echo "gj_bend n=$1 T=$2 ms=$(minms $B/mb_gj_b --threads 1 -- $1 $2)"; done
echo "## repair generation, flat arrays (1000 symbols; ~7 terms each; T octets)"
for cfg in "1000 1024" "4000 1024" "10000 1024" "1000 16"; do set -- $cfg; echo "repair_arr K=$1 T=$2 N=1000 ms=$(minms $B/mb_repair --threads 1 -- $1 $2 1000)"; done
echo "## cons-list proxy for sparse bookkeeping (map over N records, rounds)"
for cfg in "1000 10000" "100000 100"; do set -- $cfg; echo "list_bend n=$1 rounds=$2 ms=$(minms $B/mb_list --threads 1 -- $1 $2)"; taskset -c $CPU $B/mb_list_c $1 $2 | grep ms=; done
echo "## Array.get/set cost, 1M random ops (0 U32 get+set, 1 U32 get, 2 boxed get+set, 3 boxed get)"
for lg in 8 16 20; do for m in 0 1 2 3; do echo "arrops lg=$lg mode=$m ms=$(minms $B/mb_arrops --threads 1 -- $lg 1000000 $m)"; done; done
