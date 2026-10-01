#!/usr/bin/env python3
"""Generate src/tables.bend from ref/rfc6330.txt (RFC 6330 sections 5.3.5.2, 5.5, 5.6).

Usage: python3 tools/gen_tables.py [--check]

Parses the RFC text (not hand-typed), cross-checks every parsed constant
against the constants in ref/raptorq-rs/src (rng.rs, systematic_constants.rs,
base.rs), recomputes P1 with an independent primality test, and emits Bend.

Emitted lookup structure: balanced binary decision trees of top-level defs
(see docs/tables.md).  Everything is generated; do not edit src/tables.bend.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RFC = os.path.join(ROOT, "ref", "rfc6330.txt")
RS = os.path.join(ROOT, "ref", "raptorq-rs", "src")
OUT = os.path.join(ROOT, "src", "tables.bend")


def rfc_lines():
    """RFC body lines with page headers/footers and form feeds removed."""
    out = []
    for ln in open(RFC, encoding="utf-8").read().split("\n"):
        ln = ln.replace("\f", "")
        if ln.startswith("Luby, et al.") or ln.startswith("RFC 6330   "):
            continue
        out.append(ln)
    return out


def section(lines, start_re, end_re):
    i = next(k for k, l in enumerate(lines) if re.match(start_re, l))
    j = next(k for k in range(i + 1, len(lines)) if re.match(end_re, lines[k]))
    return lines[i + 1:j]


def parse_v_tables(lines):
    heads = [r"5\.5\.1\.  The Table V0", r"5\.5\.2\.  The Table V1",
             r"5\.5\.3\.  The Table V2", r"5\.5\.4\.  The Table V3", r"5\.6\.  Systematic"]
    tabs = []
    for a, b in zip(heads, heads[1:]):
        body = "\n".join(section(lines, a, b))
        nums = [int(x) for x in re.findall(r"\d+", body)]
        assert len(nums) == 256, (a, len(nums))
        assert all(0 <= n < 2**32 for n in nums)
        tabs.append(nums)
    return tabs


def parse_table2(lines):
    body = section(lines, r"5\.6\.  Systematic", r"5\.7\.  Operating")
    rows = []
    for l in body:
        m = re.match(r"\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$", l)
        if m:
            rows.append(tuple(int(g) for g in m.groups()))
    assert len(rows) == 477, len(rows)
    return rows  # (K', J, S, H, W)


def parse_deg_f(lines):
    body = section(lines, r"5\.3\.5\.2\.  Degree Generator", r"5\.3\.5\.3\.")
    f = {}
    for l in body:
        m = re.match(r"\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|(?:\s*(\d*)\s*\|\s*(\d*)\s*\|)?\s*$", l)
        if m:
            f[int(m.group(1))] = int(m.group(2))
            if m.group(3):
                f[int(m.group(3))] = int(m.group(4))
    assert sorted(f) == list(range(31)), sorted(f)
    return [f[d] for d in range(31)]


def is_prime(n):
    if n < 2:
        return False
    d = 2
    while d * d <= n:
        if n % d == 0:
            return False
        d += 1
    return True


def p1_of(kp, s, h, w):
    p = kp + s + h - w
    q = p
    while not is_prime(q):
        q += 1
    return q


# ---- cross-check against ref/raptorq-rs ----------------------------------
def rs_v_tables():
    src = open(os.path.join(RS, "rng.rs")).read()
    tabs = []
    for n in range(4):
        m = re.search(r"const V%d: \[u32; 256\] = \[(.*?)\];" % n, src, re.S)
        tabs.append([int(x) for x in re.findall(r"\d+", m.group(1))])
    return tabs


def rs_table2():
    src = open(os.path.join(RS, "systematic_constants.rs")).read()
    m = re.search(r"SYSTEMATIC_INDICES_AND_PARAMETERS: \[.*?\] = \[(.*?)\n\];", src, re.S)
    rows = [tuple(int(x) for x in t) for t in re.findall(r"\((\d+), (\d+), (\d+), (\d+), (\d+)\)", m.group(1))]
    m = re.search(r"P1_TABLE: \[.*?\] = \[(.*?)\n\];", src, re.S)
    p1 = [tuple(int(x) for x in t) for t in re.findall(r"\((\d+), (\d+)\)", m.group(1))]
    return rows, p1


def rs_deg_f():
    src = open(os.path.join(RS, "base.rs")).read()
    m = re.search(r"let f: \[u32; 31\] = \[(.*?)\];", src, re.S)
    return [int(x) for x in re.findall(r"\d+", m.group(1))]


# ---- Bend emission --------------------------------------------------------
def emit_tree(out, name, params, leaves, cond, leaf_expr, ret, doc=None):
    """Emit a balanced decision tree of defs.

    leaves: list of leaf payloads (size n).  The def `name` (taking `params`,
    a string like "+i: U32") dispatches to leaf `idx`.  cond(mid) gives the
    Bend Bool expression deciding "go left" at split index mid (in terms of
    the first parameter), leaf_expr(payload) the Bend expression of a leaf.
    Each split costs two defs because Bend cannot match on a computed value:
    `<name>.<lo>_<hi>` computes the test, `<name>.<lo>_<hi>.s` matches on it.
    """
    arg = params.split(":")[0].lstrip("+")

    def ref(lo, hi):
        return f"{name}.n{lo}_{hi}" if (lo, hi) != (0, len(leaves)) else name

    def call(lo, hi):
        if hi - lo == 1:
            return leaf_expr(leaves[lo])
        return f"{ref(lo, hi)}({arg})"

    def gen(lo, hi):
        if hi - lo == 1:
            return
        mid = (lo + hi) // 2
        gen(lo, mid)
        gen(mid, hi)
        r = ref(lo, hi)
        out.append(f"def {r}.s({params}, b: Bool) -> {ret}:")
        out.append("  match b:")
        out.append("    case True{}:")
        out.append(f"      {call(lo, mid)}")
        out.append("    case False{}:")
        out.append(f"      {call(mid, hi)}")
        out.append("")
        out.append(f"def {r}({params}) -> {ret}:")
        out.append(f"  {r}.s({arg}, {cond(mid)})")
        out.append("")

    if doc:
        out.append(doc)
    gen(0, len(leaves))


def main():
    lines = rfc_lines()
    V = parse_v_tables(lines)
    T2 = parse_table2(lines)
    F = parse_deg_f(lines)

    # cross-checks vs Rust reference constants
    assert V == rs_v_tables(), "V tables differ from raptorq-rs"
    rs_t2, rs_p1 = rs_table2()
    assert T2 == rs_t2, "Table 2 differs from raptorq-rs"
    assert F == rs_deg_f(), "Deg table differs from raptorq-rs"
    P1 = [p1_of(kp, s, h, w) for kp, j, s, h, w in T2]
    # raptorq-rs P1_TABLE has (K', P1) rows for every K'
    assert dict(rs_p1) == {r[0]: p for r, p in zip(T2, P1)}, "P1 differs from raptorq-rs"
    # sanity on the table itself
    assert [r[0] for r in T2] == sorted(r[0] for r in T2)
    assert all(is_prime(r[2]) and is_prime(r[4]) for r in T2)
    assert max(max(t) for t in V) < 2**32
    if "--check" in sys.argv:
        print("cross-checks OK: V0-V3, Table 2 (%d rows), P1, Deg f" % len(T2))

    out = []
    out.append("# GENERATED by tools/gen_tables.py from ref/rfc6330.txt -- DO NOT EDIT.")
    out.append("#")
    out.append("# RFC 6330 section 5.5 (V0..V3), 5.6 (Table 2) and 5.3.5.2 (Table 1).")
    out.append("# Lookups are balanced binary decision trees of top-level defs (O(log n),")
    out.append("# no arrays, no allocation); see docs/tables.md.")
    out.append("import Base")
    out.append("")
    out.append("# One row of Table 2 (plus P1, the smallest prime >= P = L - W).")
    out.append("type SP is Data:")
    out.append("  SP{kp: U32, j: U32, s: U32, h: U32, w: U32, p1: U32}")
    out.append("")
    for n in range(4):
        emit_tree(out, f"V{n}", "+i: U32", V[n],
                  cond=lambda mid: f"U32.is_lt(i, {mid})",
                  leaf_expr=str, ret="U32",
                  doc=f"# V{n}[i], i in 0..255 (RFC 5.5.{n+1}). i >= 256 reads V{n}[255].")
        out.append("")
    # Table 1: deg_index(v) = d with f[d-1] <= v < f[d]; leaves d = 1..30
    emit_tree(out, "deg_index", "+v: U32", list(range(1, 31)),
              cond=lambda mid: f"U32.is_lt(v, {F[mid]})",
              leaf_expr=str, ret="U32",
              doc="# Table 1 (RFC 5.3.5.2): d in 1..30 with f[d-1] <= v < f[d], v < 2^20.")
    out.append("")
    rows = [SProw for SProw in zip(T2, P1)]
    emit_tree(out, "sp_row", "+k: U32", rows,
              cond=lambda mid: f"U32.is_le(k, {rows[mid-1][0][0]})",
              leaf_expr=lambda r: "SP{%d, %d, %d, %d, %d, %d}" % (r[0][0], r[0][1], r[0][2], r[0][3], r[0][4], r[1]),
              ret="SP",
              doc="# Row of Table 2 for the smallest K' >= k (k <= 56403; larger k gives the last row).")
    out.append("")
    with open(OUT, "w") as f:
        f.write("\n".join(out))
    print("wrote", OUT, "(%d lines)" % len(out))


if __name__ == "__main__":
    main()
