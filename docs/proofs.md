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
| `Flat.of_vec`/`Flat.to_vec` round trip, flat kernels = `Vec` ops, flat `Codec.symbols`/`decode` = tree path | `to_vec(len v, of_vec(v)) == v` (shape included) for the balanced `Vec.from_list` shape; `xr/cp/zr/ms/ma` slice loops equal `Vec.xor/scale/muladd`; the array-based encoder equals `C.encode_idx` per ESI | tested only (`tests/flat_test.bend`: 0..40, 255..257, 1000 words, offsets, 24 kernel cases, K = 10..100 with T = 4,5,16,20,64,1024; golden vectors in `tests/codec_test.bend` go through the flat path). Not proven: array reads/writes are Base primitives, the tree shape (`c >> 1` left halves) is an invariant of `Vec.build`, not a checked precondition of `Flat.put_vec` | `src/flat.bend` |
| flat phase 1 = list phase 1 | `Solver.plan` (phase 1 on one `Array<U32>`: CSR rows, static column index, linked-list buckets, logs derived from the final column states) gives the same plan as `Solver.plan_ref` (the list version): same pivots in the same order, same logs (as multisets), original terms, tail rows and tail solution; both `None` on rank-deficient systems | tested only: `tests/solver_plan_test.bend` (structural comparison, K = 10, 26, 100, 500, 1000: encoder system, repair-only, stride-7 repair, mixed/duplicate ESIs), `tests/solver_test.bend` (24 synthetic systems incl. rank-deficient, `solve_dense` oracle), golden RFC intermediate symbols (`tests/solver_golden_test.bend`). Not proven: array reads/writes are Base primitives; the invariant "a row's active part never changes except by losing columns" (no fill-in) is argued in `docs/solver.md`, not a checked precondition; dense rows are classified by raw length, which is only a performance choice (a dense row is just never a pivot) | `src/solver.bend` section 6b |
| program interpreter = list replay, sliced apply = unsliced apply | `Solver.apply` / `apply_arena` (plan compiled to a 3-word-instruction `Array<U32>` and interpreted) equal the earlier list replay; `apply_par` / `apply_ars` / sliced decode / `Codec.symbols_par` equal the unsliced results for any slicing depth d (word slices of the balanced `Vec`s, `vjoin` of the halves has the shape `Vec.from_list` builds) | tested only: `tests/solver_test.bend` (`solve_par` d = 1), `tests/solver_golden_test.bend` (`apply_par` d = 3 and the other payloads), `tests/codec_auto_test.bend` (sliced decode, `symbols_par` d = 2, 3, odd word counts 5 / 9), `tests/codec_plan_test.bend`. Not proven (arrays, forks and `Array.clone` are Base primitives; the compiler sees only fork-free leaf defs) | `src/solver.bend` 9b, `src/flat.bend` |
| linear flat encoder = `Codec.symbols` | `Codec.symbols_flat(encoder_flat(d, ..), esi0, n)` read out with `Codec.out_vecs` equals `Codec.symbols(Codec.encoder(..), esi0, n)` for every d (also on the encoder handed back by a first call) | tested only: `tests/codec_flat_test.bend` (K = 10..300, T = 5, 16, 36, 64, 512, 1024, d = 0, 1, 2, 3 and auto, plan reuse, `NoF` edge cases) | `src/flat.bend`, `src/raptorq.bend` |
| `partition_laws` | `Partition[I,J] = (IL,IS,JL,JS)`: `IL*JL + IS*JS = I`, `JL + JS = J`, `IS <= IL <= IS+1`, `JL < J` (block sizes add up to the object) | TODO proof (needs the `U32.div`/`mod` identity of Base, same obstacle as `rand_bound`); tested: 70 x 70 grid + 118 crate vectors in `tests/blocks_test.bend` | not stated as a law |
| `split_object`/`join_object` round trip (Z blocks, N sub-blocks), `decode_object(encode_object(d)) = d` | | tested only: 11 crate objects, 33 loss scenarios (`tests/blocks_test.bend`, docs/multiblock.md) | not stated as a law |
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
