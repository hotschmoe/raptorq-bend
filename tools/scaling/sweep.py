#!/usr/bin/env python3
"""Scaling sweep: python3 tools/scaling/sweep.py <binary> <reps> <threads, e.g. 1,2,4,8,12> "<args>" ["<args>" ...]
Runs `binary --threads N -- <args>` (min ms of <reps> runs) and prints one table row per args line: ms at each thread count and the
speedup vs 1 thread.  Threads <= 8 are confined to the 8 big cores (taskset BIG), 1 thread to one A720 (cpu 10); 12 threads are
unpinned (the 4 Cortex-A520 are ~3.5x slower than the A720s, see docs/scaling.md).  Env PIN1 / BIG override the sets."""
import os, re, subprocess, sys

binary, reps, threads = sys.argv[1], int(sys.argv[2]), [int(x) for x in sys.argv[3].split(',')]
BIG = os.environ.get('BIG', '0,1,6,7,8,9,10,11')
PIN1 = os.environ.get('PIN1', '10')

def run(args, th):
    best, chk = None, None
    for _ in range(reps):
        cmd = [binary] + os.environ.get('RTFLAGS', '').split() + ['--threads', str(th), '--'] + args.split()
        if th == 1:
            cmd = ['taskset', '-c', PIN1] + cmd
        elif th <= 8:
            cmd = ['taskset', '-c', BIG] + cmd
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        m = re.search(r'ms=(\d+)', out)
        if not m:
            return None, out.strip()
        ms = int(m.group(1))
        best = ms if best is None else min(best, ms)
        chk = re.search(r'chk=(\d+)', out).group(1) if 'chk=' in out else ''
    return best, chk

print('load', open('/proc/loadavg').read().split()[:3])
print('%-28s' % 'args', ''.join('%8s' % ('t=%d' % t) for t in threads), ' | speedup', ''.join('%7s' % ('x%d' % t) for t in threads))
for args in sys.argv[4:]:
    ms, chks = [], set()
    for t in threads:
        m, c = run(args, t)
        ms.append(m)
        chks.add(c)
    base = ms[0]
    sp = ['%7.2f' % (base / m) if (m and base) else '    n/a' for m in ms]
    print('%-28s' % args, ''.join('%8s' % (m if m is not None else '-') for m in ms), ' |', ' ', ''.join(sp), '' if len(chks) == 1 else ' CHK-MISMATCH %s' % chks, flush=True)
