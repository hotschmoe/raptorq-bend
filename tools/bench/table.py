#!/usr/bin/env python3
"""Markdown tables (min over reps) from build/bench_results.txt written by tools/bench/run.sh.  Usage: tools/bench/table.py [file]"""
import sys, collections
f = sys.argv[1] if len(sys.argv) > 1 else "build/bench_results.txt"
best = collections.defaultdict(lambda: 1e18)
for line in open(f):
    p = line.split()
    kv = dict(x.split("=") for x in p[1:])
    who = p[0] + ("/" + kv["threads"] if p[0] == "BEND" else "")
    for m in ("setup_ms", "setup_cold_ms", "setup_warm_ms", "repair_ms", "decode_ms"):
        if m in kv:
            k = (int(kv["K"]), int(kv["T"]), who, m)
            best[k] = min(best[k], float(kv[m]))
keys = sorted({(k, t) for (k, t, w, m) in best})
thr = sorted({w for (k, t, w, m) in best if w.startswith("BEND/")}, key=lambda s: int(s.split("/")[1]))

def fmt(x):
    return "%.1f" % x if x < 10 else "%d" % round(x)

def table(title, rust_m, bend_m):
    print("\n### " + title + "\n")
    print("| K | T | Rust (ms) | " + " | ".join("Bend %s thr (ms) | Bend/Rust" % w.split("/")[1] for w in thr) + " |")
    print("|---|---|---|" + "---|---|" * len(thr))
    for (k, t) in keys:
        r = best[(k, t, "RUST", rust_m)]
        cells = []
        for w in thr:
            b = best[(k, t, w, bend_m)]
            cells.append("%s | %.1fx" % (fmt(b), b / max(r, 0.05)) if r >= 0.05 else "%s | >%dx" % (fmt(b), round(b / 0.05)))
        print("| %d | %d | %s | %s |" % (k, t, fmt(r), " | ".join(cells)))

table("Encoder setup, Rust cold (fresh process: plan generation = the solve)", "setup_cold_ms", "setup_ms")
table("Encoder setup, Rust warm (plan cached, only replayed)", "setup_warm_ms", "setup_ms")
table("Generate 1000 repair symbols", "repair_ms", "repair_ms")
table("Decode from K symbols (7/8 repair)", "decode_ms", "decode_ms")
