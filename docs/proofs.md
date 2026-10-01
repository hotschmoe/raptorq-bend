# Laws and proofs

`LAWS.bend` (repo root) states the properties the codec must never break; `PROOF.bend` proves them with one
`def Laws.<name>` per law. The gate is

    scripts/check_proofs.sh               # bend PROOF.bend -> ALL PROOFS CHECK (about 2 s), law/proof count, open-law count
    scripts/check_proofs.sh --runtime     # + bend src/laws_check.bend: runtime-checked laws (about 10 s)
    scripts/check_proofs.sh --tamper      # + a scratch copy with a deliberately broken def must FAIL (about 5 s)
    bend PROOF.bend                       # the proofs only

`bend PROOF.bend --verdict` (second check with the Lean kernel) was not run: no Lean/elan on this machine (it needs
Lean v4.34.0). Everything below is "bend2 checker accepts", not "kernel re-checked".

Files: `LAWS.bend` (19 laws), `PROOF.bend` (proofs + lemmas), `src/laws_defs.bend` (`Same`, `muladd_nz`),
`src/laws_verify.bend` (`verify`, `Solver.solve_checked`, `Codec.decode_checked`, `Vec.eq`), `src/laws_open.bend`
(12 laws stated but not proven; `bend src/laws_open.bend` prints SOME PROOFS FAIL by design), `src/laws_check.bend`
(runtime checks). No file under `src/` other than `laws_*.bend` was changed; the codec does not import any of them.

## Status table

Status: **proven** = checked by `bend PROOF.bend`; **runtime** = `bend src/laws_check.bend` (or the listed test
program) executes it on many inputs; **tested** = covered only by the existing test suites / differential vectors.

| law | statement | status | where |
|---|---|---|---|
| `verify_sound` | `verify(rows, sol) == True` implies every row equation `sum coef*C[col] == rhs` holds (propositionally, through a proven `Vec.eq` soundness: word compare -> `Word.cmp` -> equality) | proven | LAWS 1, PROOF "verify / solve_checked" |
| `solve_checked_sound` | `Solver.solve_checked(l,p,rows) == Some(sol)` implies `verify(rows, sol) == True`; with `verify_sound`: a checked solution satisfies all equations | proven (by construction: `Some` is only built from the `True` branch) | LAWS 1 |
| `xor_self` | `xor(a,a) == zeros(a)` | proven | LAWS 2 |
| `xor_zero` | `xor(a, zeros(a)) == a` | proven | LAWS 2 |
| `xor_comm` | `xor(a,b) == xor(b,a)` for equal shapes (`Same`) | proven | LAWS 2 |
| `xor_assoc` | `xor(xor(a,b),c) == xor(a,xor(b,c))` for equal shapes | proven | LAWS 2 |
| `xor_inv` | `xor(xor(a,b),b) == a`, any shapes | proven | LAWS 2 |
| `xor_shape` | `Same(xor(a,b), a)` (result shape = first operand's) | proven | LAWS 2 |
| `muladd_zero`, `muladd_one` | `muladd(0,d,s) == d`; `muladd(1,d,s) == xor(d,s)` | proven | LAWS 3 |
| `muladd_invol` | `muladd_nz(c, muladd_nz(c,d,s), s) == d` for every c (the branch `muladd` takes for c not in {0,1}); row operations are reversible | proven | LAWS 3 |
| `add_comm`, `add_assoc`, `add_self`, `add_zero` | octet addition is an abelian group with a+a=0 (bit level: Bool -> Word(n) -> U32 by induction) | proven | LAWS 4 (the first, third, fourth were already proven in `src/gf256.bend`) |
| `split_length` | `length(Codec.split(data,t)) == k_of(len(data), t)` (exactly K symbols) | proven | LAWS 5 |
| `params_L`, `params_P`, `params_B` | `L = K'+S+H`, `P = L-W`, `B = W-S` (definitional, pins `R.L/P/B`) | proven | LAWS 6 |
| `rand_bound` | `Rand[y,i,m] < m` for m > 0 | runtime: 20000x2 LCG samples + 8 edge cases; the proof needs the 32-step shift/subtract invariant of `U32.mod` (Base) | `src/laws_open.bend`, `src/laws_check.bend` |
| `params_ge`, `params_smallest` | `K <= K'`; K' is the smallest Table 2 row >= K (`params`) | runtime: every K in 0..56403: `K <= K'`, `K'` is a fixed point, `K'` monotone, `L/P/U/B` identities (`U = P-H` included), RFC spot values, `params(56404) = None`; also `tests/tables_test.bend` (hash over every K, golden rows) | same |
| `split_symbol_words` | every symbol of `split` has ceil(T/4) words | runtime (21 (len,T) shapes, zero padding of the last symbol included); `tests/codec_test.bend` | same |
| `join_split` | `join(split(d,t), t, len d) == d` | runtime (same 21 shapes) + `tests/codec_test.bend` (lengths 0..4096) | same |
| `decode_checked_consistent` | `Codec.decode_checked` answers `Some(out)` only if the intermediate symbols satisfy every received row, so re-encoding `out` reproduces every received symbol | runtime: K = 1,10,26,50; with one corrupted symbol among K+2 received, plain `Codec.decode` still returns `Some` while `decode_checked` returns `None`; `verify` rejects a tampered solution (K = 1,10,26) | `src/laws_check.bend`; solver half proven (`solve_checked_sound`) |
| `roundtrip` | for any subset of genuine encoder symbols, `decode` is `None` (rank deficient) or exactly the source; success is not claimed | tested only: `tests/codec_test.bend` (1056 loss patterns, `None` => dense oracle also rank deficient) and differential decode vectors against the Rust crate (`tests/vectors`, `tests/vectors2`, incl. 15 cases where the Rust decoder fails) | stated in `src/laws_open.bend` |
| `mul_comm`, `mul_assoc`, `mul_dist`, `mul_one`, `mul_inv` | GF(256) field laws for octets | tested only: exhaustive over all 256x256 pairs in `tests/gf256_test.bend` | `src/laws_open.bend` |
| `mulw` = per-octet `mul` (SWAR), `Vec.muladd` = zipWith | | tested only: `tests/gf256_test.bend` (every c, every lane) | not stated as a law |
| table = RFC 6330 5.5/5.6 | a data fact | tested only: generators in `tools/` cross-check the RFC text, raptorq-rs and a Python field | |

Also proven in `src/gf256.bend` itself (checked by `bend src/gf256.bend`): `bool_xor_comm`, `word_xor_comm`,
`word_xor_self`, `word_xor_zero`, `add_comm`, `add_self`, `add_zero`, `mul_zero_l`, `div_zero_l`.

### What the proven laws do and do not say

* `Vec.xor`/`muladd` take a fork depth computed from the left operand (`fork_levels`). `PROOF.bend` first proves the
  result is independent of the depth (`xor_indep`, `ma_indep`), so every law is about the real public def, not a
  sequential model. Shapes: the ops zip trees; on a shape mismatch they return the first operand's subtree. `xor_inv`,
  `xor_shape`, `muladd_invol` hold regardless; commutativity/associativity need `Same` (otherwise false).
* `verify` is only as good as its definition (`nth`, `Row.eval` = `muladd` fold from `zeros(rhs)`, `Vec.eq`). `Vec.eq`'s
  soundness is proven, its completeness (equal vectors give `True`) is not needed for soundness and is only exercised
  at runtime (`verify` accepts the golden solutions). `solve_checked_sound` is the guarantee that the solver result is
  *checked*, not that `solve_p` is correct: `solve_p` itself is verified by the golden and differential tests
  (`docs/solver.md`).
* `split_length` is about the list length; the per-symbol size and `join(split)` are runtime-checked.

## Tamper demonstration

A proof that cannot fail is worthless. `scripts/check_proofs.sh --tamper` copies `LAWS.bend`, `PROOF.bend` and `src/`
to a scratch directory, replaces the leaf operation of `Vec.xor` (`VWord{U32.xor(x, y)}` by `VWord{U32.or(x, y)}`, the
kind of "optimisation" a refactor could introduce) and runs `bend PROOF.bend`. Result: `SOME PROOFS FAIL` with
`expected : {G.VWord{U32.or(w, 0)} == G.VWord{w} : G.Vec}  observed : {G.VWord{U32.xor(w, 0)} == ...}` at `xor_zero_go`
(`xor_self`, `xor_comm` etc. cite the XOR-based `G.add_*` lemmas and would no longer match either); the script reports `tamper: detected`. A second tampering,
`Vec.eq` answering `True{}` for every pair of words, fails `vec_eq_sound` ("expected `Cmp.is_eq(U32.cmp(x, y)) == True`,
observed `True{} == True{}`"), i.e. a checker that accepts everything cannot be passed off as sound.
At runtime the same idea is `src/laws_check.bend`: flipping one bit of a solution or of a received symbol must make
`verify` / `decode_checked` fail.

## Idioms and gotchas found while proving (Bend 2 checker)

* A law is `law name: for +x: T ... {lhs == rhs : T}`; if the claim is a type (not an equality) write it without braces
  (`D.Same(..)`, `V.Sat(..)`). A proof is `def Laws.name(x, ..)`. Params the proof uses twice need `+` in the law header,
  and pattern variables used twice need `+`/`1n++p`. Hypotheses are ordinary `for h: {..}` params.
* A `match` cannot scrutinize a computed value (e.g. `Word.cmp(..)`, `split.next(..)`): the lemma takes the value as a parameter
  and the caller passes the induction hypothesis as a lambda (`.k` helpers in `PROOF.bend`). Recursion must be on the first
  parameter; `match` follows parameter order, so a lemma that matches `fk` before `a` lists `fk` first.
* `%e : P` rewrites the goal where `_` marks the **rhs** of `e` (the goal is `P` with the rhs there, afterwards with the
  lhs). `vnode_cong`/`Equal.cong`/`Equal.trans` chains were more robust than long rewrite sequences.
* Refuting a case: if a type reduces to `Empty` (`Same(VNil, VWord{..})`), `match s:` with no cases closes it.
  For `{False{} == True{}}`/`{LT{} == EQ{}}` rewrite through a type-valued helper (`BD`, `CD`, `DM`) that is `Unit` on the
  wrong side.
* Literal matches on `U32` (`case 0: .. case 1: .. case _:`) compile to a bit-level decision tree and the checker keeps
  the default branch refined as "31 zero bits and a bit that is not False" without reducing it: goals that mention
  `G.mul`/`Vec.muladd` for a symbolic coefficient get stuck. Workarounds: state the law on the worker
  (`muladd_nz`) and the trivial branches separately. This is also why the GF(256) `mul` laws (which would be provable
  structurally from `U32.add_comm` and the log/exp tables) were not attempted.
* The 65536-case `mul` laws are not finite-case provable in reasonable time here; they stay exhaustively tested.
* `Maybe.default(&2, T, m, [])` + `Equal.cong` gives `Some` injectivity.
* Imports of big modules are cheap: `bend PROOF.bend` (imports tables, solver, raptorq) takes about 2 s.
