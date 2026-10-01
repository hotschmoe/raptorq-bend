#!/usr/bin/env python3
"""Independent Python reference for RFC 6330 Rand / Deg / Tuple / parameters,
plus the emitter for tests/tables_test.bend (golden values).

Usage:
  python3 tools/ref_funcs.py                  # self-check + print a sample
  python3 tools/ref_funcs.py --emit-test      # (re)write tests/tables_test.bend
  python3 tools/ref_funcs.py tuple KP X       # print Tuple[K',X]

Independence: the algorithms below are written straight from RFC text with
Python big integers (no 32-bit tricks except the RFC's own mod 2^32), and the
tables are read from the RFC text (gen_tables parsers) and asserted equal to
the constants in ref/raptorq-rs.  The Rust crate's own `rand`, `deg` and
`intermediate_tuple` (ref/raptorq-rs/src/{rng,base}.rs) are additionally
re-implemented in `rust_style_*` below, transliterated from that source, and
compared with the RFC-style implementation on many inputs.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tables as G  # noqa: E402  (parsers + Rust constant extraction only)

ROOT = G.ROOT
_lines = G.rfc_lines()
V = G.parse_v_tables(_lines)
T2 = G.parse_table2(_lines)
F = G.parse_deg_f(_lines)
assert V == G.rs_v_tables() and T2 == G.rs_table2()[0] and F == G.rs_deg_f()
KPS = [r[0] for r in T2]
ROW = {r[0]: r for r in T2}


# ---- RFC 5.3.5.1 ----------------------------------------------------------
def rand(y, i, m):
    assert 0 <= y and 0 <= i < 256 and m > 0
    x0 = (y + i) % 2**8
    x1 = ((y // 2**8) + i) % 2**8
    x2 = ((y // 2**16) + i) % 2**8
    x3 = ((y // 2**24) + i) % 2**8
    return (V[0][x0] ^ V[1][x1] ^ V[2][x2] ^ V[3][x3]) % m


# ---- RFC 5.3.5.2 ----------------------------------------------------------
def deg(v, w):
    assert 0 <= v < 2**20
    d = next(d for d in range(1, 31) if F[d - 1] <= v < F[d])
    return min(d, w - 2)


# ---- RFC 5.6 / 5.3.3.3 ----------------------------------------------------
def k_to_kp(k):
    return next(kp for kp in KPS if kp >= k)


def params(kp):
    _, j, s, h, w = ROW[kp]
    l = kp + s + h
    p = l - w
    p1 = p
    while not G.is_prime(p1):
        p1 += 1
    return dict(kp=kp, j=j, s=s, h=h, w=w, l=l, p=p, p1=p1, u=p - h, b=w - s)


# ---- RFC 5.3.5.4 ----------------------------------------------------------
def tuple_(kp, x):
    q = params(kp)
    j, w, p1 = q["j"], q["w"], q["p1"]
    a = 53591 + j * 997
    if a % 2 == 0:
        a += 1
    b = 10267 * (j + 1)
    y = (b + x * a) % 2**32
    v = rand(y, 0, 2**20)
    d = deg(v, w)
    aa = 1 + rand(y, 1, w - 1)
    bb = rand(y, 2, w)
    d1 = 2 + rand(x, 3, 2) if d < 4 else 2
    a1 = 1 + rand(x, 4, p1 - 1)
    b1 = rand(x, 5, p1)
    return (d, aa, bb, d1, a1, b1)


# ---- transliteration of raptorq-rs (u32 arithmetic) -----------------------
M = 2**32 - 1


def rust_style_rand(y, i, m):
    x0 = ((y + i) & M) % 256
    x1 = (((y >> 8) + i) & M) % 256
    x2 = (((y >> 16) + i) & M) % 256
    x3 = (((y >> 24) + i) & M) % 256
    return (V[0][x0] ^ V[1][x1] ^ V[2][x2] ^ V[3][x3]) % m


def rust_style_deg(v, w):
    for d in range(1, len(F)):
        if v < F[d]:
            return min(d, w - 2)


def rust_style_tuple(x, w, j, p1):
    A = 53591 + j * 997
    if A % 2 == 0:
        A += 1
    B = 10267 * (j + 1)
    y = (B + x * A) % 4294967296
    v = rust_style_rand(y, 0, 1048576)
    d = rust_style_deg(v, w)
    a = 1 + rust_style_rand(y, 1, w - 1)
    b = rust_style_rand(y, 2, w)
    d1 = 2 + rust_style_rand(x, 3, 2) if d < 4 else 2
    a1 = 1 + rust_style_rand(x, 4, p1 - 1)
    b1 = rust_style_rand(x, 5, p1)
    return (d, a, b, d1, a1, b1)


def self_check():
    rng = random.Random(6330)
    for _ in range(20000):
        y = rng.getrandbits(32)
        i = rng.randrange(256)
        m = rng.randrange(1, 2**rng.randrange(1, 33))
        assert rand(y, i, m) == rust_style_rand(y, i, m)
    for kp in KPS[::7] + [KPS[-1]]:
        q = params(kp)
        for x in list(range(0, min(q["l"], 300))) + [rng.randrange(q["l"]) for _ in range(200)]:
            assert tuple_(kp, x) == rust_style_tuple(x, q["w"], q["j"], q["p1"]), (kp, x)
    for w in (17, 19, 101, 56951):
        for v in [0, 2**20 - 1] + [f for f in F[1:-1]] + [f - 1 for f in F[1:-1]]:
            assert deg(v, w) == rust_style_deg(v, w)
    # U32 range audit for the Bend implementation
    for kp in KPS:
        q = params(kp)
        a = 53591 + q["j"] * 997
        assert a + 1 < 2**32 and 10267 * (q["j"] + 1) < 2**32
    # P1 must equal the Rust crate's P1_TABLE
    rs_p1 = dict(G.rs_table2()[1])
    assert all(params(kp)["p1"] == rs_p1[kp] for kp in KPS)


# ---- hashing identical to the Bend test -----------------------------------
def hs(h, v):
    return (h * 31 + v) % 2**32


def hash_seq(vals, h=7):
    for v in vals:
        h = hs(h, v)
    return h


def hash_table(n):
    return hash_seq(V[n])


def hash_tuples(kp, n=None):
    q = params(kp)
    h = 7
    for x in range(q["l"] if n is None else n):
        for f in tuple_(kp, x):
            h = hs(h, f)
    return h


def hash_params():
    h = 7
    for k in range(0, 56404):
        q = params(k_to_kp(k))
        for f in ("kp", "j", "s", "h", "w", "p1", "l", "p", "u", "b"):
            h = hs(h, q[f])
    return h


# ---- test emission --------------------------------------------------------
HEAD = '''# GENERATED by tools/ref_funcs.py --emit-test -- DO NOT EDIT.
# Golden values come from the independent Python reference in tools/ref_funcs.py
# (RFC text tables, cross-checked against ref/raptorq-rs).
#
# Run (from the repo root):  bend tests/tables_test.bend
# Prints one PASS/FAIL line per group; exits non-zero on any failure.
import Base
import ../src/tables.bend as T
import ../src/rfc_funcs.bend as R

# 0 if equal, 1 otherwise
def ck.go(eq: Bool) -> U32:
  match eq:
    case True{}:
      0
    case False{}:
      1

def ck(+a: U32, +b: U32) -> U32:
  ck.go(U32.is_eq(a, b))

# h*31 + v (mod 2^32); the same fold as tools/ref_funcs.py
def hs(+h: U32, +v: U32) -> U32:
  (h * 31 + v : U32)

def hash_tup(h: U32, t: R.Tup) -> U32:
  match t:
    case R.Tup{d, a, b, d1, a1, b1}:
      hs(hs(hs(hs(hs(hs(h, d), a), b), d1), a1), b1)

def eq_tup(+t: R.Tup, d: U32, a: U32, b: U32, d1: U32, a1: U32, b1: U32) -> U32:
  match t:
    case R.Tup{+td, +ta, +tb, +td1, +ta1, +tb1}:
      (ck(td, d) + ck(ta, a) + ck(tb, b) + ck(td1, d1) + ck(ta1, a1) + ck(tb1, b1) : U32)

# --- hash loops (each lookup goes through the public generated defs) ---------

def hash_v0(+n: Nat, +i: U32, +h: U32) -> U32:
  match n:
    case 0n:
      h
    case 1n+p:
      hash_v0(p, (i + 1 : U32), hs(h, T.V0(i)))

def hash_v1(+n: Nat, +i: U32, +h: U32) -> U32:
  match n:
    case 0n:
      h
    case 1n+p:
      hash_v1(p, (i + 1 : U32), hs(h, T.V1(i)))

def hash_v2(+n: Nat, +i: U32, +h: U32) -> U32:
  match n:
    case 0n:
      h
    case 1n+p:
      hash_v2(p, (i + 1 : U32), hs(h, T.V2(i)))

def hash_v3(+n: Nat, +i: U32, +h: U32) -> U32:
  match n:
    case 0n:
      h
    case 1n+p:
      hash_v3(p, (i + 1 : U32), hs(h, T.V3(i)))

# fold hs over the ten derived fields of the row for K' = Kp(sp)
def hash_sp(+sp: T.SP, h: U32) -> U32:
  hs(hs(hs(hs(hs(hs(hs(hs(hs(hs(h, R.Kp(sp)), R.J(sp)), R.S(sp)), R.H(sp)), R.W(sp)), R.P1(sp)), R.L(sp)), R.P(sp)), R.U(sp)), R.B(sp))

def hash_params.go(+n: Nat, +k: U32, +h: U32) -> U32:
  match n:
    case 0n:
      h
    case 1n+p:
      hash_params.go(p, (k + 1 : U32), hash_sp(T.sp_row(k), h))

# K = 0..56403 (56404 lookups)
def hash_params() -> U32:
  hash_params.go(56404n, 0, 7)

# hash of Tuple[K', X] for X = 0..n-1 where sp is the row for K'
def hash_tuples(+sp: T.SP, +n: Nat, +x: U32, +h: U32) -> U32:
  match n:
    case 0n:
      h
    case 1n+p:
      hash_tuples(sp, p, (x + 1 : U32), hash_tup(h, R.tuple(sp, x)))

def hash_tuples_all.go(+sp: T.SP, h: U32) -> U32:
  hash_tuples(sp, U32.to_nat(R.L(sp)), 0, h)

# Tuple[K', X] for X in 0..L-1
def hash_tuples_all(+kp: U32) -> U32:
  hash_tuples_all.go(T.sp_row(kp), 7)

# --- result reporting ---------------------------------------------------------

def line.go(name: String, +f: U32, ok: Bool) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ name ++ " (" ++ U32.show(f) ++ " mismatches)"

def line(name: String, +f: U32) -> String:
  line.go(name, f, U32.is_zero(f))

def done.go(+f: U32, ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ALL TESTS PASSED")
    case False{}:
      IO.die(Unit, 1, "FAILED: " ++ U32.show(f) ++ " mismatches in total")

def done(+f: U32) -> IO(Unit):
  done.go(f, U32.is_zero(f))
'''


def emit_test():
    rng = random.Random(0xC0FFEE)
    out = [HEAD]
    # -- table hashes + spot values
    out.append("def t_tables() -> U32:")
    for n in range(4):
        out.append(f"  v{n} = ck(hash_v{n}(256n, 0, 7), {hash_table(n)})")
        for i in (0, 1, 127, 128, 254, 255):
            out.append(f"  s{n}_{i} = ck(T.V{n}({i}), {V[n][i]})")
    names = [f"v{n}" for n in range(4)] + [f"s{n}_{i}" for n in range(4) for i in (0, 1, 127, 128, 254, 255)]
    out.append("  (" + " + ".join(names) + " : U32)")
    out.append("")

    # -- Rand
    cases = []
    ys = [0, 1, 2, 255, 256, 257, 65535, 65536, 2**24 - 1, 2**24, 2**31, 2**32 - 256, 2**32 - 2, 2**32 - 1]
    ms = [1, 2, 3, 7, 17, 101, 1000, 2**20, 56402, 2**31, 2**32 - 1]
    for y in ys:
        for i in (0, 1, 5, 255):
            cases.append((y, i, rng.choice(ms)))
    for _ in range(120):
        cases.append((rng.getrandbits(32), rng.randrange(256), rng.choice(ms + [rng.randrange(1, 2**32)])))
    out.append("def t_rand() -> U32:")
    for n, (y, i, m) in enumerate(cases):
        out.append(f"  r{n} = ck(R.rand({y}, {i}, {m}), {rand(y, i, m)})")
    out.append("  (" + " + ".join(f"r{n}" for n in range(len(cases))) + " : U32)")
    out.append("")

    # -- Deg
    out.append("def t_deg() -> U32:")
    dc = []
    for w in (17, 19, 101, 56951):
        vs = [0, 2**20 - 1] + F[1:-1] + [f - 1 for f in F[1:-1]]
        dc += [(v, w) for v in vs]
    for n, (v, w) in enumerate(dc):
        out.append(f"  d{n} = ck(R.deg({v}, {w}), {deg(v, w)})")
    out.append("  (" + " + ".join(f"d{n}" for n in range(len(dc))) + " : U32)")
    out.append("")

    # -- K -> K' and derived params
    out.append("def t_params() -> U32:")
    ks = [0, 1, 9, 10, 11, 12, 13, 18, 19, 20, 100, 101, 1000, 4096, 10000, 40000, 56402, 56403]
    ks += [rng.randrange(0, 56404) for _ in range(20)]
    pf = ("kp", "j", "s", "h", "w", "p1", "l", "p", "u", "b")
    fn = dict(kp="Kp", j="J", s="S", h="H", w="W", p1="P1", l="L", p="P", u="U", b="B")
    stmts = []
    for n, k in enumerate(ks):
        q = params(k_to_kp(k))
        for f in pf:
            out.append(f"  p{n}_{f} = ck(R.{fn[f]}(T.sp_row({k})), {q[f]})")
            stmts.append(f"p{n}_{f}")
    out.append("  hp = ck(hash_params(), %d)" % hash_params())
    stmts.append("hp")
    out.append("  (" + " + ".join(stmts) + " : U32)")
    out.append("")
    out.append("# params() is None above K'max, Some below")
    out.append("def t_params_opt.go(m: Maybe<&2, T.SP>) -> U32:")
    out.append("  match m:")
    out.append("    case Some{+sp}:")
    out.append("      R.Kp(sp)")
    out.append("    case None{}:")
    out.append("      0")
    out.append("")
    out.append("def t_params_opt() -> U32:")
    out.append("  (ck(t_params_opt.go(R.params(56403)), 56403) + ck(t_params_opt.go(R.params(56404)), 0)"
               " + ck(t_params_opt.go(R.params(0)), 10) + ck(t_params_opt.go(R.params(11)), 12) : U32)")
    out.append("")

    # -- Tuple: explicit values
    out.append("def t_tuple_explicit() -> U32:")
    tc = []
    for kp in sorted({k_to_kp(k) for k in (10, 12, 18, 26, 101, 500, 1002, 8192, 56403)}):
        q = params(kp)
        xs = sorted({0, 1, 2, 3, kp - 1, kp, q["l"] - 1, 7, 100 % q["l"], rng.randrange(q["l"])})
        xs = [x for x in xs if 0 <= x < q["l"]]
        tc += [(kp, x) for x in xs]
    stmts = []
    for n, (kp, x) in enumerate(tc):
        t = tuple_(kp, x)
        out.append(f"  e{n} = eq_tup(R.tuple(T.sp_row({kp}), {x}), {', '.join(map(str, t))})")
        stmts.append(f"e{n}")
    out.append("  (" + " + ".join(stmts) + " : U32)")
    out.append("")

    # -- Tuple: all X in 0..L-1 via hash
    allk = sorted({k_to_kp(k) for k in (10, 12, 18, 20, 26, 30, 101, 250, 1002, 4096, 10000, 56403)})
    out.append("# one def per K' so each runs independently")
    for kp in allk:
        out.append(f"def t_tuple_all_{kp}() -> U32:")
        out.append(f"  ck(hash_tuples_all({kp}), {hash_tuples(kp)})")
        out.append("")

    # -- main
    groups = [("tables V0..V3 (hash of all 4x256 entries + spot values)", "t_tables"),
              (f"Rand ({len(cases)} cases)", "t_rand"),
              (f"Deg ({len(dc)} cases)", "t_deg"),
              (f"K->K' + S,H,W,J,P1,L,P,U,B ({len(ks)} K, + hash of all K in 0..56403)", "t_params"),
              ("params() Maybe", "t_params_opt"),
              (f"Tuple explicit ({len(tc)} values)", "t_tuple_explicit")]
    groups += [(f"Tuple K'={kp}, all X in 0..L-1 (hash)", f"t_tuple_all_{kp}") for kp in allk]
    out.append("def main() -> IO(Unit):")
    out.append("  do IO<Unit>:")
    for n, (title, fn_) in enumerate(groups):
        out.append(f"    +f{n} : U32 = {fn_}()")
        out.append(f'    IO.print(line("{title}", f{n}))')
    out.append("    done((" + " + ".join(f"f{n}" for n in range(len(groups))) + " : U32))")
    path = os.path.join(ROOT, "tests", "tables_test.bend")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write("\n".join(out) + "\n")
    print("wrote", path)


if __name__ == "__main__":
    args = sys.argv[1:]
    self_check()
    if args[:1] == ["--emit-test"]:
        emit_test()
    elif args[:1] == ["tuple"]:
        print(tuple_(int(args[1]), int(args[2])))
    else:
        print("self-check OK (RFC-style == raptorq-rs-style on all sampled inputs)")
        print("Tuple[10,3] =", tuple_(10, 3))
