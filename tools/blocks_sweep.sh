#!/usr/bin/env bash
# Speedup sweep of the multi-block encode (fused encode + repair) and decode (docs/multiblock.md): Z blocks of K symbols of T octets at
# --threads 1,2,4,8,12 (min of REPS runs), with
#   calib   the register-loop calibration of the same block tree (what the scheduler + cores give for perfectly parallel pure compute)
#   plain   the block tree with plain forks, w = threads leaves        bang   the same with the tree called as f!(..) (clang 19)
#   over    plain forks with w = 64 leaves (more leaves than threads)  priv   W independent sub-objects, every one with its own plan
#   procs   the CEILING: t independent single-thread PROCESSES (one per core), each doing Z/t blocks, max over the processes: what the box and
#           the allocator allow without any Bend scheduler (every process computes its own plan)
# Rows with t <= 8 are pinned to the 8 big cores (taskset -c 0,1,6,7,8,9,10,11; t = 1 to cpu10), t = 12 is unpinned (the 4 little A520 cores
# are ~3.5x slower).  Needs clang 19 for tools/blocks_lab.bend (see its header); override the clang dir with CLANG_DIR.
# Usage: tools/blocks_sweep.sh [Z=64] [K=1000] [T=1024] [REPS=3]      output: build/blocks_sweep.txt (raw lines) and the summary on stdout
set -euo pipefail
cd "$(dirname "$0")/.."
Z=${1:-64}; K=${2:-1000}; T=${3:-1024}; REPS=${4:-3}
CLANG_DIR=${CLANG_DIR:-/tmp/claude-1001/-home-hotschmoe-github/91cf6a5d-8121-4501-98d0-349f7735ac39/scratchpad/clang19}
export PATH="$HOME/.bend/bin:$CLANG_DIR:/usr/bin:/bin" BEND_NO_TELEMETRY=1
mkdir -p build
bend tools/blocks_lab.bend -o build/blocks_lab >/dev/null
OUT=build/blocks_sweep.txt
echo "# $(date +%F\ %T) load: $(cut -d' ' -f1-3 /proc/loadavg)  Z=$Z K=$K T=$T reps=$REPS" | tee "$OUT"
BIG=(10 11 0 1 6 7 8 9)
BIGSET=0,1,6,7,8,9,10,11
pin() { local t=$1; if [ "$t" = 1 ]; then echo "taskset -c 10"; elif [ "$t" -le 8 ]; then echo "taskset -c $BIGSET"; else echo ""; fi; }
lab() { # label t w bang
  $(pin $2) ./build/blocks_lab --threads "$2" --gpu off -- bench "$Z" "$K" "$T" "$3" "$4" | grep '^LAB' | sed "s/^/$1 t=$2 /" | tee -a "$OUT"
}
for t in 1 2 4 8 12; do
  for r in $(seq "$REPS"); do
    $(pin $t) ./build/blocks_lab --threads "$t" --gpu off -- calib 64 50000000 "$t" 0 | grep '^CALIB' | sed "s/^/calib t=$t /" | tee -a "$OUT"
    lab plain "$t" "$t" 0
    if [ "$t" -gt 1 ]; then
      lab bang "$t" "$t" 1
      lab over "$t" 64 0
      $(pin $t) ./build/blocks_lab --threads "$t" --gpu off -- priv "$Z" "$K" "$T" "$t" 0 | grep '^CHUNK' | sed "s/^/priv t=$t /" | tee -a "$OUT"
    fi
    if [ "$t" -le 8 ]; then   # ceiling: t processes, one per big core, Z/t blocks each
      zp=$((Z / t)); pids=()
      for i in $(seq 0 $((t - 1))); do
        ( taskset -c "${BIG[$i]}" ./build/blocks_lab --threads 1 --gpu off -- bench "$zp" "$K" "$T" 1 0 | grep '^LAB' > "build/proc_$i.txt" ) & pids+=($!)
      done
      wait "${pids[@]}"
      cat build/proc_*.txt | python3 -c "
import sys
e = d = 0
for l in sys.stdin:
    kv = dict(p.split('=') for p in l.split()[1:])
    e = max(e, int(kv['enc_ms'])); d = max(d, int(kv['dec_ms']))
print('procs t=$t LAB Z=$Z K=$K T=$T w=$t enc_ms=%d dec_ms=%d' % (e, d))" | tee -a "$OUT"
      rm -f build/proc_*.txt
    fi
  done
done
python3 - "$OUT" <<'PY'
import sys, re, collections
best = collections.defaultdict(lambda: 1e18)
for line in open(sys.argv[1]):
    if line.startswith('#'): print(line.strip()); continue
    m = re.match(r'(\w+) t=(\d+) (CALIB|LAB|CHUNK) (.*)', line)
    if not m: continue
    lab, t = m.group(1), int(m.group(2)); kv = dict(p.split('=') for p in m.group(4).split())
    if m.group(3) == 'CALIB': best[('calib', t, 'ms')] = min(best[('calib', t, 'ms')], float(kv['ms']))
    elif m.group(3) == 'CHUNK': best[(lab, t, 'ms')] = min(best[(lab, t, 'ms')], float(kv['enc_dec_ms']))
    else:
        for k in ('enc_ms', 'dec_ms'):
            best[(lab, t, k)] = min(best[(lab, t, k)], float(kv[k]))
ts = sorted({k[1] for k in best})
def row(lab, key, base):
    out = []
    for t in ts:
        v = best.get((lab, t, key))
        out.append('   -        ' if v is None or v > 1e17 else '%6.0f %4.2fx %3.0f%%' % (v, base / v, 100 * base / v / t))
    return ' | '.join(out)
for key, name in (('enc_ms', 'encode + repair'), ('dec_ms', 'decode')):
    base = best[('plain', 1, key)]
    print("\n%s (ms, speedup vs plain 1 thread, parallel efficiency)   threads: %s" % (name, ' '.join(map(str, ts))))
    for lab in ('plain', 'bang', 'over', 'procs'):
        print('  %-6s %s' % (lab, row(lab, key, base)))
cb = best[('calib', 1, 'ms')]
print("\ncalib (register loop, same tree):  " + ' | '.join('%6.0f %4.2fx' % (best[('calib', t, 'ms')], cb / best[('calib', t, 'ms')]) for t in ts))
base = best[('plain', 1, 'enc_ms')] + best[('plain', 1, 'dec_ms')]
print("priv (encode+decode, own plans) vs plain+plain: " + ' | '.join('t=%d %4.0f vs %4.0f' % (t, best[('priv', t, 'ms')], best[('plain', t, 'enc_ms')] + best[('plain', t, 'dec_ms')]) for t in ts if ('priv', t, 'ms') in best))
PY
