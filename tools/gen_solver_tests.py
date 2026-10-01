#!/usr/bin/env python3
"""Generate tests/solver_fixtures.bend: synthetic GF(256) linear systems with known solutions.

Stream layout (flat list of U32 literals, symbols are SYMW=2 packed words = 8 octets):
  [nsys]
  per system: [l, p, nrows, expect]            expect: 1 = solvable (full rank), 0 = rank < l (expect None)
              nrows x [nterms, (col, coef)*nterms, w0, w1]
              if expect == 1: l x [w0, w1]      the unique solution C[0..l-1]
Deterministic (fixed seeds).  Run from the repo root:  python3 tools/gen_solver_tests.py
"""
import random, sys, os

# ---- GF(256), x^8+x^4+x^3+x^2+1 (RFC 6330 5.7) -------------------------------------------------
EXP = [0] * 510
LOG = [0] * 256
x = 1
for i in range(255):
    EXP[i] = x
    LOG[x] = i
    x <<= 1
    if x & 0x100:
        x ^= 0x11D
for i in range(255, 510):
    EXP[i] = EXP[i - 255]

def mul(a, b):
    if a == 0 or b == 0:
        return 0
    return EXP[LOG[a] + LOG[b]]

SYMW = 2  # words per symbol

def rand_sym(rng):
    return [rng.randrange(256) for _ in range(4 * SYMW)]

def pack(sym):
    return [(sym[4*k] << 24) | (sym[4*k+1] << 16) | (sym[4*k+2] << 8) | sym[4*k+3] for k in range(SYMW)]

def rhs_of(terms, sol):
    out = [0] * (4 * SYMW)
    for col, coef in terms:
        s = sol[col]
        for j in range(4 * SYMW):
            out[j] ^= mul(coef, s[j])
    return out

def rank(l, rows):
    m = [[0] * l for _ in rows]
    for i, terms in enumerate(rows):
        for c, f in terms:
            m[i][c] ^= f
    r = 0
    for c in range(l):
        piv = next((i for i in range(r, len(m)) if m[i][c]), None)
        if piv is None:
            continue
        m[r], m[piv] = m[piv], m[r]
        inv = EXP[255 - LOG[m[r][c]]]
        m[r] = [mul(inv, v) for v in m[r]]
        for i in range(len(m)):
            if i != r and m[i][c]:
                f = m[i][c]
                m[i] = [a ^ mul(f, b) for a, b in zip(m[i], m[r])]
        r += 1
    return r

def dense_row(rng, l):
    return [(c, rng.randrange(256)) for c in range(l)]

def raptorq_like(rng, l, p, extra):
    """Sparse, mostly binary rows shaped like the RaptorQ constraint matrix:
    S LDPC-ish rows, H dense GF(256) 'HDPC' rows, LT rows (weight 2..5 on the first w=l-p cols plus
    2 PI columns), `extra` overhead rows.  Term order inside a row is shuffled."""
    w = l - p
    h = max(2, l // 12)
    s = max(2, l // 10)
    rows = []
    for i in range(s):                      # LDPC-like: 3 binary terms + identity on a PI-ish column
        cols = rng.sample(range(w), min(3, w))
        rows.append([(c, 1) for c in cols] + [(w + (i % max(p, 1)) if p else i % l, 1)])
    for i in range(h):                      # HDPC-like: dense GF(256)
        rows.append([(c, rng.randrange(1, 256)) for c in range(l) if rng.random() < 0.9])
    n_lt = l - s - h + extra
    for i in range(n_lt):
        d = rng.choice([2, 2, 2, 3, 3, 4, 5])
        cols = rng.sample(range(w), min(d, w))
        pis = rng.sample(range(w, l), min(2, p)) if p else []
        rows.append([(c, 1) for c in cols + pis])
    for r in rows:
        rng.shuffle(r)
    return rows

def make_system(rng, l, p, rows, expect):
    sol = [rand_sym(rng) for _ in range(l)]
    out = [l, p, len(rows), expect]
    for terms in rows:
        out.append(len(terms))
        for c, f in terms:
            out += [c, f]
        out += pack(rhs_of(terms, sol))
    if expect:
        for s in sol:
            out += pack(s)
    return out

def main():
    rng = random.Random(6330)
    systems = []
    def add(l, p, rows, expect, name):
        r = rank(l, rows)
        assert (r == l) == bool(expect), (name, l, r)
        systems.append(make_system(rng, l, p, rows, expect))
        print("  %-28s l=%-3d rows=%-3d p=%-2d expect=%d" % (name, l, len(rows), p, expect), file=sys.stderr)

    for l in (1, 2, 5, 8, 13, 21, 34, 60):           # dense, square
        while True:
            rows = [dense_row(rng, l) for _ in range(l)]
            if rank(l, rows) == l:
                break
        add(l, 0, rows, 1, "dense square")
    for l, ex in ((10, 4), (21, 6), (40, 10)):       # dense, overdetermined (consistent)
        rows = [dense_row(rng, l) for _ in range(l + ex)]
        add(l, 0, rows, 1, "dense overdetermined")
    # rank deficient
    rows = [dense_row(rng, 10) for _ in range(10)]
    rows[7] = list(rows[3])
    add(10, 0, rows, 0, "dense duplicate row")
    rows = [dense_row(rng, 12) for _ in range(12)]
    add(13, 0, rows, 0, "fewer rows than cols")
    rows = [[(c, f) for c, f in dense_row(rng, 30) if c != 17] for _ in range(34)]
    add(30, 0, rows, 0, "dense zero column")
    # sparse, RaptorQ-shaped
    for l, p, ex in ((12, 3, 3), (20, 4, 3), (30, 5, 4), (40, 6, 4), (80, 9, 5), (150, 12, 6), (150, 0, 8)):
        while True:
            rows = raptorq_like(rng, l, p, ex)
            if rank(l, rows) == l:
                break
        add(l, p, rows, 1, "raptorq-like")
    # sparse rank deficient: a column that no row mentions
    rows = raptorq_like(rng, 40, 6, 6)
    rows = [[(c, f) for c, f in r if c != 11] for r in rows]
    add(40, 6, rows, 0, "sparse missing column")
    # sparse with duplicate column entries inside one row (must XOR) and a zero coefficient
    rows = raptorq_like(rng, 30, 5, 4)
    rows[0] = rows[0] + [(rows[0][0][0], rows[0][0][1])] + [(rows[0][0][0], 7), (rows[0][0][0], 7), (0, 0)]
    add(30, 5, rows, 1, "sparse duplicate terms") if True else None

    flat = [len(systems)]
    for s in systems:
        flat += s
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "tests", "solver_fixtures.bend")
    with open(path, "w") as f:
        f.write("# GENERATED by tools/gen_solver_tests.py -- DO NOT EDIT.\n")
        f.write("# Synthetic GF(256) systems with known solutions (layout: see the generator).\n")
        # a single huge literal overflows the checker's stack: emit CHUNK-sized defs and append them
        CHUNK = 600
        chunks = [flat[i:i + CHUNK] for i in range(0, len(flat), CHUNK)]
        for k, ch in enumerate(chunks):
            f.write("def chunk%d() -> List<&2, U32>:\n  [%s]\n\n" % (k, ", ".join(str(v) for v in ch)))
        # append from the back, tail position, one def per step to keep expansion shallow
        f.write("def fixtures() -> List<&2, U32>:\n")
        expr = "chunk%d()" % (len(chunks) - 1)
        for k in range(len(chunks) - 2, -1, -1):
            expr = "List.append(&2, U32, chunk%d(), %s)" % (k, expr)
        f.write("  " + expr + "\n")
    print("wrote %s: %d systems, %d numbers" % (path, len(systems), len(flat)), file=sys.stderr)

main()
