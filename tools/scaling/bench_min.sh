#!/usr/bin/env bash
# min over reps of the BEND line fields: tools/scaling/bench_min.sh <binary> <reps> <threads> <K> <T> [N]
# threads 1 -> pinned to cpu10; <= 8 -> the 8 big cores; 12 -> unpinned
B=$1; R=$2; TH=$3; K=$4; T=$5; N=${6:-1000}
if [ "$TH" = 1 ]; then PIN="taskset -c 10"; elif [ "$TH" -le 8 ]; then PIN="taskset -c 0,1,6,7,8,9,10,11"; else PIN=""; fi
for i in $(seq $R); do $PIN $B --threads $TH -- $K $T $N | grep '^BEND'; done | python3 -c "
import sys,re,collections
best={}
for l in sys.stdin:
    for m in re.finditer(r'(\w+_ms)=(\d+)',l):
        best[m.group(1)]=min(best.get(m.group(1),1e9),int(m.group(2)))
print('K=$K T=$T thr=$TH',' '.join('%s=%d'%(k,v) for k,v in best.items()), 'load', open('/proc/loadavg').read().split()[0])"
