#!/usr/bin/env bash
# prints the least busy of the big (A720) cores over a 1 s sample; usage: taskset -c $(tools/scaling/quietcore.sh) ...
BIG="0 1 6 7 8 9 10 11"
a=$(grep '^cpu[0-9]' /proc/stat); sleep 1; b=$(grep '^cpu[0-9]' /proc/stat)
python3 - "$BIG" <<PY
import sys
big=[int(x) for x in sys.argv[1].split()]
def parse(t):
    d={}
    for l in t.strip().split('\n'):
        p=l.split(); n=int(p[0][3:]); v=list(map(int,p[1:]))
        d[n]=(sum(v), v[3]+v[4])
    return d
a=parse("""$a"""); b=parse("""$b""")
busy={c: 1-((b[c][1]-a[c][1])/max(1,(b[c][0]-a[c][0]))) for c in big}
best=min(busy,key=busy.get)
import sys as s
print(best)
s.stderr.write(' '.join('%d:%.0f%%'%(c,busy[c]*100) for c in big)+'\n')
PY
