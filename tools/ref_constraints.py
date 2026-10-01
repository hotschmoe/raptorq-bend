#!/usr/bin/env python3
"""INDEPENDENTLY DERIVED reference for RFC 6330 constraint matrix A and tuples.

This script does NOT use the cberner/raptorq crate. It re-implements, straight from
ref/rfc6330.txt, for K' in {10, 26}:
  - tables V0..V3 (5.5, parsed from the RFC text), degree table (5.3.5.2), Table 2 params (5.6)
  - Rand (5.3.5.1), Deg (5.3.5.2), Tuple (5.3.5.4), Enc (5.3.5.3)
  - GF(256) (5.7; poly 0x11D, alpha=2; tables computed, not copied)
  - rows of matrix A (5.3.3.3 LDPC + HDPC relations, 5.3.3.4.2 / Fig. 6 LT rows)
It writes tests/vectors/constraints.txt and tests/vectors/tuples.txt and then CROSS-CHECKS
the crate-generated vectors (intermediate.txt, encoded.txt): A * C == [0.., source..] and
repair symbols == Enc[...] over C. Exit code != 0 on any mismatch.

Usage: python3 tools/ref_constraints.py        (run from repo root, after tools/vectors)
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RFC = os.path.join(ROOT, "ref", "rfc6330.txt")
VEC = os.path.join(ROOT, "tests", "vectors")
KPS = [10, 26]

txt = open(RFC).read()
lines = [l for l in txt.split("\n")
         if not l.startswith("Luby, et al.") and not l.startswith("RFC 6330   ")]
txt = "\n".join(lines)

def table(name, nxt):
    a = txt.index("5.5.%d.  The Table %s\n" % (int(name[1]) + 1, name))
    b = txt.index(nxt, a)
    nums = [int(x) for x in re.findall(r"\d+", txt[a:b].split("\n", 1)[1])]
    assert len(nums) == 256, (name, len(nums))
    return nums

V = [table("V0", "5.5.2."), table("V1", "5.5.3."), table("V2", "5.5.4."),
     table("V3", "5.6.  Systematic")]

# degree table f[0..30]
a = txt.index("Index d | f[d]")
b = txt.index("Table 1: Defines the Degree")
f = {}
for d, v in re.findall(r"\|\s*(\d+)\s*\|\s*(\d+)\s*\|", txt[a:b]):
    pass
for m in re.finditer(r"\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(?:(\d+)\s*\|\s*(\d+)\s*\|)?", txt[a:b]):
    f[int(m.group(1))] = int(m.group(2))
    if m.group(3):
        f[int(m.group(3))] = int(m.group(4))
F = [f[i] for i in range(31)]
assert F[0] == 0 and F[30] == 1048576 and len(f) == 31

# Table 2
a = txt.index("| K'    | J(K') | S(K') | H(K') | W(K') |")
T2 = {}
for m in re.finditer(r"\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|", txt[a:txt.index("Table 2: Systematic Indices")]):
    T2[int(m.group(1))] = tuple(int(m.group(i)) for i in range(2, 6))  # J,S,H,W
assert len(T2) == 477, len(T2)

# GF(256)
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
def mul(u, v):
    return 0 if u == 0 or v == 0 else EXP[LOG[u] + LOG[v]]

def is_prime(n):
    return n >= 2 and all(n % d for d in range(2, int(n ** 0.5) + 1))

def rand(y, i, m):
    x0 = (y + i) % 256
    x1 = ((y >> 8) + i) % 256
    x2 = ((y >> 16) + i) % 256
    x3 = ((y >> 24) + i) % 256
    return (V[0][x0] ^ V[1][x1] ^ V[2][x2] ^ V[3][x3]) % m

def deg(v, W):
    for d in range(1, 31):
        if F[d - 1] <= v < F[d]:
            return min(d, W - 2)

class Params:
    def __init__(s, Kp):
        s.Kp = Kp
        s.J, s.S, s.H, s.W = T2[Kp]
        s.L = Kp + s.S + s.H
        s.P = s.L - s.W
        s.P1 = s.P
        while not is_prime(s.P1):
            s.P1 += 1
        s.B = s.W - s.S
        s.U = s.P - s.H

def tup(p, X):
    A = 53591 + p.J * 997
    if A % 2 == 0:
        A += 1
    B = 10267 * (p.J + 1)
    y = (B + X * A) % 2 ** 32
    v = rand(y, 0, 2 ** 20)
    d = deg(v, p.W)
    a = 1 + rand(y, 1, p.W - 1)
    b = rand(y, 2, p.W)
    d1 = 2 + rand(X, 3, 2) if d < 4 else 2
    a1 = 1 + rand(X, 4, p.P1 - 1)
    b1 = rand(X, 5, p.P1)
    return d, a, b, d1, a1, b1

def enc_cols(p, X):
    """column set (as dict col->octet) of the Enc[] linear combination for ISI X (5.3.5.3)"""
    d, a, b, d1, a1, b1 = tup(p, X)
    cols = {}
    def tog(c):
        cols[c] = cols.get(c, 0) ^ 1
    tog(b)
    for _ in range(1, d):
        b = (b + a) % p.W
        tog(b)
    while b1 >= p.P:
        b1 = (b1 + a1) % p.P1
    tog(p.W + b1)
    for _ in range(1, d1):
        b1 = (b1 + a1) % p.P1
        while b1 >= p.P:
            b1 = (b1 + a1) % p.P1
        tog(p.W + b1)
    return {c: v for c, v in cols.items() if v}

def ldpc_rows(p):
    rows = [dict() for _ in range(p.S)]
    def tog(r, c):
        rows[r][c] = rows[r].get(c, 0) ^ 1
    for i in range(p.S):
        tog(i, p.B + i)
    for i in range(p.B):
        a = 1 + i // p.S
        b = i % p.S
        tog(b, i)
        b = (b + a) % p.S
        tog(b, i)
        b = (b + a) % p.S
        tog(b, i)
    for i in range(p.S):
        tog(i, p.W + i % p.P)
        tog(i, p.W + (i + 1) % p.P)
    return [{c: v for c, v in r.items() if v} for r in rows]

def hdpc_rows(p):
    n = p.Kp + p.S
    MT = [[0] * n for _ in range(p.H)]
    for j in range(n - 1):
        r1 = rand(j + 1, 6, p.H)
        r2 = (r1 + rand(j + 1, 7, p.H - 1) + 1) % p.H
        MT[r1][j] = 1
        MT[r2][j] = 1
    for i in range(p.H):
        MT[i][n - 1] = EXP[i]
    rows = []
    for i in range(p.H):
        r = {}
        for j in range(n):
            acc = 0
            for l in range(j, n):          # GAMMA[l,j] = alpha^(l-j), l>=j
                if MT[i][l]:
                    acc ^= mul(MT[i][l], EXP[l - j])
            if acc:
                r[j] = acc
        r[n + i] = 1                        # identity on the H HDPC symbols
        rows.append(r)
    return rows

def build_A(p):
    """rows of A (Fig. 6, K=K' so no padding rows): S LDPC, H HDPC, K' LT(ISI 0..K'-1)"""
    return ldpc_rows(p) + hdpc_rows(p) + [enc_cols(p, x) for x in range(p.Kp)]

def readsyms(name, K, T):
    out = {}
    for l in open(os.path.join(VEC, name)):
        if l.startswith("#") or not l.strip():
            continue
        v = l.split()
        if int(v[0]) == K and int(v[1]) == T:
            out[int(v[2])] = [int(x) for x in v[3:]]
    return out

def combine(row, C, T):
    r = [0] * T
    for c, v in row.items():
        for t in range(T):
            r[t] ^= mul(v, C[c][t])
    return r

def main():
    hdr = ("# INDEPENDENTLY DERIVED by tools/ref_constraints.py from ref/rfc6330.txt (NOT from the raptorq crate).\n"
           "# Lines starting with '#' are comments. Decimal, whitespace separated.\n")
    cons = [hdr + "# Non-zero entries of the RFC 6330 constraint matrix A (Fig. 6 / 5.3.3.3), one row per line:\n"
            "#   Kp row kind n col_0 val_0 ... col_{n-1} val_{n-1}\n"
            "# kind 0=LDPC (rows 0..S-1), 1=HDPC (rows S..S+H-1, vals are GF(256) octets, 5.3.3.3),\n"
            "# 2=LT row for source ISI X=row-S-H (X in 0..K'-1, 5.3.5.3 over Tuple[K',X]). Columns 0..L-1 index C[].\n"
            "# vals of LDPC/LT rows are 1. Rows are the matrix rows in order, i.e. A*C = (0^(S+H), C'[0..K'-1]).\n"]
    tups = [hdr + "# Tuple[K',X] (5.3.5.4) for X=0..K'+19:\n#   Kp X d a b d1 a1 b1\n"]
    for Kp in KPS:
        p = Params(Kp)
        A = build_A(p)
        for r, row in enumerate(A):
            kind = 0 if r < p.S else (1 if r < p.S + p.H else 2)
            ent = sorted(row.items())
            cons.append("%d %d %d %d %s\n" % (Kp, r, kind, len(ent), " ".join("%d %d" % e for e in ent)))
        for X in range(Kp + 20):
            tups.append("%d %d %s\n" % (Kp, X, " ".join(map(str, tup(p, X)))))
        # ---- cross-check against crate vectors (K<=K'; K'-K zero padding symbols, 5.3.1;
        # repair ESI K+i has ISI K'+i, 5.3.4.2)
        for K in {10: (1, 2, 10), 26: (26,)}[Kp]:
          for T in (16, 32, 5):
            C = readsyms("intermediate.txt", K, T)
            E = readsyms("encoded.txt", K, T)
            if not C:
                continue
            assert len(C) == p.L, (K, T, len(C), p.L)
            for r, row in enumerate(A):
                got = combine(row, C, T)
                X = r - p.S - p.H
                want = [0] * T if (X < 0 or X >= K) else E[X]
                assert got == want, ("A*C mismatch", K, T, r)
            nrep = len(E) - K
            for i in range(nrep):
                got = combine(enc_cols(p, Kp + i), C, T)
                assert got == E[K + i], ("repair mismatch", K, T, i)
            print("K=%d K'=%d T=%d OK: A*C matches (%d rows), %d repair symbols match" % (K, Kp, T, len(A), nrep))
    open(os.path.join(VEC, "constraints.txt"), "w").write("".join(cons))
    open(os.path.join(VEC, "tuples.txt"), "w").write("".join(tups))

main()
