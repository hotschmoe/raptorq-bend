# Tables, Rand, Deg, Tuple (RFC 6330 5.3.5, 5.5, 5.6)

Files: `src/tables.bend` (generated), `src/rfc_funcs.bend`, `tests/tables_test.bend` (generated),
`tools/gen_tables.py`, `tools/ref_funcs.py`.

## Regenerate / test
    python3 tools/gen_tables.py --check     # parse RFC, cross-check vs ref/raptorq-rs, write src/tables.bend
    python3 tools/ref_funcs.py --emit-test  # independent Python reference -> tests/tables_test.bend
    bend tests/tables_test.bend             # prints PASS/FAIL lines, exit 1 on any failure (~6 s)

## Lookup structure: decision trees of defs
Arrays are affine (a read hands the array back; every Rand would have to thread four of them), and
`Array.get` also walks 8 levels. Instead each table is a balanced binary tree of *top-level defs*:
`V0` tests `i < mid`, dispatches to `V0.n0_128` / `V0.n128_256`, ... down to a literal. This is O(log n)
(8 steps for V0..V3, 9 for the 477-row Table 2, 5 for Table 1), needs no value to be threaded or
cloned, can be called any number of times from anywhere (including parallel branches), and the
constants live in code, not in the heap. Micro-benchmark on this machine: 3M lookups into a 256-entry
table took ~0.1 s as a tree versus ~0.65 s for a 256-case literal `match` chain. Bend cannot `match`
a computed value, so each node is two defs: `X(i)` computes `U32.is_lt(i, mid)` and `X.s(i, b)` matches
the Bool. Defs must be declared before use, so children are emitted before parents.
K -> K' is the same tree keyed on K' itself (`U32.is_le(k, K'[mid-1])`), so one search yields
`SP{kp, j, s, h, w, p1}` (the whole Table 2 row plus P1) for the smallest K' >= K.

P1 (smallest prime >= P) is precomputed by the generator (trial division) and equals raptorq-rs's
`P1_TABLE` for all 477 rows; L, P, U, B are derived in Bend by `R.L/P/U/B` (pure adds/subs).

## U32 audit
Bend `U32` ops are 32-bit Word ops: `+ - *` wrap mod 2^32, `.^. .&. .|.` bitwise, `>> n` takes a Nat
shift, `%` is a 32-step divmod (and `x % 0 = x`). Rand: `y + i` can exceed 2^32 but only its low 8 bits
are used, so wrap is harmless; `y >> 8k` plus i, `& 255` fits trivially; XOR of four U32 and `% m` fit.
Tuple: `A = 53591 + 997 J` (< 1.1e6), `B = 10267 (J+1)` (< 1e7) fit; `y = (B + X*A) mod 2^32` is the one
product that overflows, and the RFC defines it mod 2^32, which is exactly U32 wraparound (raptorq-rs
computes it in u64 then reduces). `Rand[y,0,2^20]` has m = 2^20 < 2^32. `Deg`'s W-2, `Rand[...,W-1]`
etc. are small. Nothing needs more than 32 bits.

## Cross-checks
* `gen_tables.py` parses V0..V3, Table 1, Table 2 from `ref/rfc6330.txt` (page breaks stripped) and
  asserts equality with the constants in raptorq-rs `rng.rs`, `base.rs`, `systematic_constants.rs`.
* `ref_funcs.py` implements Rand/Deg/Tuple from the RFC with Python ints, and also a transliteration
  of the raptorq-rs functions; they are compared on 20000+ random Rand inputs and many tuples.
* The Bend test compares against golden values: all 4x256 table entries (hash) + spot values, 176
  Rand cases (edge y near 2^32), 240 Deg boundary cases, 38 K -> (K',J,S,H,W,P1,L,P,U,B) rows plus a
  hash over every K in 0..56403, 89 explicit tuples, and a hash of Tuple[K',X] for all X in 0..L-1 for
  12 K' (10 ... 56403).
