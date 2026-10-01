#!/usr/bin/env python3
"""Generate the GF(256) tables of RFC 6330 section 5.7 into Bend source.

Sources / checks (all must agree, else this script exits non-zero):
  1. OCT_EXP (510 entries) and OCT_LOG (255 entries) parsed from ref/rfc6330.txt.
  2. The same tables parsed from ref/raptorq-rs/src/octet.rs (Rust reference).
  3. The field generated independently from x^8+x^4+x^3+x^2+1 (0x11D), alpha=2.
  4. All 256x256 products: shift-xor multiply == OCT_EXP[LOG+LOG] (RFC formula).

Writes the region between `# BEGIN GENERATED` / `# END GENERATED` in
src/gf256.bend (tables) and tests/gf256_test.bend (checksums of the full
mul / div tables, computed here from the independent field).
Usage: python3 tools/gen_gf256.py
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
RFC = (ROOT / "ref/rfc6330.txt").read_text()
RS = ROOT / "ref/raptorq-rs/src/octet.rs"


def rfc_exp():
    t = "5.7.3.  The Table OCT_EXP"
    s = [m.start() for m in re.finditer(re.escape(t), RFC)][-1]
    e = RFC.index("5.7.4.  The Table OCT_LOG", s)
    body = RFC[s + len(t):e]
    body = re.sub(r"Luby, et al\..*?\[Page \d+\]", " ", body)
    body = re.sub(r"RFC 6330\s+RaptorQ FEC Scheme\s+August 2011", " ", body)
    body = body[body.index("representation:") + 15:]
    return [int(x) for x in re.findall(r"\d+", body)]


def rfc_log():
    t = "5.7.4.  The Table OCT_LOG"
    s = [m.start() for m in re.finditer(re.escape(t), RFC)][-1]
    e = RFC.index("5.7.5.  Operations on Symbols", s)
    body = RFC[s + len(t):e]
    body = re.sub(r"Luby, et al\..*?\[Page \d+\]", " ", body)
    body = re.sub(r"RFC 6330\s+RaptorQ FEC Scheme\s+August 2011", " ", body)
    body = body[body.index("the entries are the following:") + 30:]
    return [int(x) for x in re.findall(r"\d+", body)]


def rs_table(name):
    src = RS.read_text()
    m = re.search(r"const %s: \[u8; \d+\] = \[(.*?)\];" % name, src, re.S)
    return [int(x) for x in re.findall(r"\d+", m.group(1))]


def field():
    exp, x = [], 1
    for _ in range(510):
        exp.append(x)
        x <<= 1
        if x & 0x100:
            x ^= 0x11D
    log = [0] * 256
    for i in range(255):
        log[exp[i]] = i
    return exp, log


def slow_mul(a, b):
    r = 0
    for _ in range(8):
        if b & 1:
            r ^= a
        a <<= 1
        if a & 0x100:
            a ^= 0x11D
        b >>= 1
    return r


def main():
    exp, log = rfc_exp(), rfc_log()
    assert len(exp) == 510, len(exp)
    assert len(log) == 255, len(log)
    log = [0] + log  # index 0 is excluded by the RFC; use a dummy 0
    # RFC OCT_LOG list starts at index 1
    rs_exp, rs_log = rs_table("OCT_EXP"), rs_table("OCT_LOG")
    assert rs_exp == exp, "RFC OCT_EXP != raptorq-rs"
    assert rs_log[1:] == log[1:], "RFC OCT_LOG != raptorq-rs"
    fexp, flog = field()
    assert fexp == exp, "RFC OCT_EXP != generated field"
    assert flog[1:] == log[1:], "RFC OCT_LOG != generated field"
    # exhaustive products and quotients
    mulh = divh = 0
    for a in range(256):
        for b in range(256):
            p = 0 if a == 0 or b == 0 else exp[log[a] + log[b]]
            assert p == slow_mul(a, b), (a, b)
            assert p == slow_mul(b, a)
            mulh = (mulh * 31 + p) & 0xFFFFFFFF
            if b:
                q = 0 if a == 0 else exp[log[a] - log[b] + 255]
                assert slow_mul(q, b) == a
                divh = (divh * 31 + q) & 0xFFFFFFFF
    for a in range(1, 256):
        assert slow_mul(a, exp[255 - log[a]]) == 1
    print("tables verified: RFC == raptorq-rs == generated field; 65536 products OK")
    print("mul checksum", mulh, "div checksum", divh)

    def fn(name, arg, vals, doc):
        out = [f"# {doc}", f"def {name}({arg}: U32) -> U32:", f"  match {arg}:"]
        for i, v in enumerate(vals):
            out += [f"    case {i}:", f"      {v}"]
        out += ["    case _:", "      0", ""]
        return "\n".join(out)

    gen = fn("oct_exp", "i", exp, "OCT_EXP (RFC 5.7.3), 510 entries; index >= 510 gives 0.") + "\n" + \
          fn("oct_log", "x", log, "OCT_LOG (RFC 5.7.4); index 0 is excluded by the RFC (dummy 0).")
    splice(ROOT / "src/gf256.bend", gen)
    tst = f"def MUL_CHECKSUM() -> U32:\n  {mulh}\n\ndef DIV_CHECKSUM() -> U32:\n  {divh}\n"
    splice(ROOT / "tests/gf256_test.bend", tst)


def splice(path, text):
    s = path.read_text()
    a, b = "# BEGIN GENERATED\n", "# END GENERATED"
    i, j = s.index(a) + len(a), s.index(b)
    path.write_text(s[:i] + text + s[j:])


main()
