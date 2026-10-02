# Plan / apply: separating the symbol-independent part of the solve (RFC 6330 5.4.2.2)

`Solver.plan(l, p, rows) -> Maybe<Plan>` solves everything that depends only on the coefficient matrix; `Solver.apply(plan, rhs)`
replays it on the symbols. `solve_p`/`solve`/`solve_par`/`solve_auto` are now `plan` + `apply` (`solve_dense` is untouched, the
oracle). Same answers bit for bit (all suites pass; the benchmark checksums of C equal the old solver's).

## Design
Everything the old solver did to symbols is a GF(256)-linear combination of the input rhs symbols with coefficients that depend
only on the matrix, so the plan stores those combinations (all lists, `Data`, duplicable, no `Array` inside):
* `PP{id, pc, finv, log, oc}` per pivot (selection order): input row `id`, pivot column, inverse of the original coefficient at
  `pc`, the elimination log `[(g, j)]` and the original terms without `pc`.
* `TR{id, log}` per tail row (leftover sparse rows and the HDPC rows corrected for every pivot; their log is `[(g_k, k)]`).
* `TC{col, [(i, f)]}` per inactive column: the solution of the dense tail as one row of `M = A_tail^-1`, sparse list over tail rows.
Plan side = phase 1 (unchanged, no longer carries `r0`/`rhs`) + materialisation of the inactive coefficient vectors + dense-row
correction (coefficients only) + the tail Gauss-Jordan (`dg_run_s`, reused) in which the rhs of tail row `i` is the unit vector
`e_i` (m octets), so the result of the elimination is `M` itself. Apply side (`apply.*`):
`R_k = rhs[id_k] + sum g R_j` (pivots), `R'_i = rhs[id_i] + sum g R_k` (tail rows), `C[col] = sum f R'_i` (inactive columns),
then forward substitution `C[pc_k] = finv_k (rhs[id_k] + sum f C[c])` through the original equations. Row `i` of the system is
rhs symbol `i` (`Solver.plan_rows(plan)` of them, one common length; the plan does not know T).
`solve_par` now plans once and applies to 2^d symbol slices concurrently (before: every slice repeated phase 1 and the coefficient
work). `Solver.apply_par(d, plan, rhs)`, `Solver.apply_auto(plan, rhs) : IO`.

Codec (`src/raptorq.bend`): `Codec.plan_for(k, esis)` (decoder plan for these received ESIs, in this order),
`Codec.encoder_plan(k)` (= `plan_for(k, 0..k-1)`: the encoder is a decoder that received all source symbols),
`Codec.encode_with_plan(k, t, plan, source)`, `Codec.decode_with_plan(k, t, plan, syms)` and `_auto` IO variants. The plan depends
on K and the ESIs only; the rhs list is `S+H` zero symbols ++ the symbols ++ `K'-K` zero symbols (built inside).

## Tests
`bend tests/solver_test.bend` (24 synthetic systems: apply(plan) equals the known solution / `None`; the same plan on a
T = 4 octet and a doubled-T payload), `bend tests/solver_golden_test.bend` (RFC intermediate symbols bit for bit via apply and
apply_par d=3 + the two other payloads), `bend tests/codec_plan_test.bend` (all golden encoder/decoder vectors through
plan_for/encode_with_plan/decode_with_plan incl. the 15 failure cases -> `plan_for` is `None`; second payload with T+12 octets
on the same plan equals `Codec.encoder`; misfits; `_auto`). `bash scripts/test_all.sh`: 9 suites pass.

## Measurements
Machine as in docs/benchmarks.md (12 cores, heterogeneous), native binaries, IO main, min of 3 runs, other agents were using the
machine (load average 2-3), so +-10 % noise. Harness: `tools/bench/bench.bend` (OLD = tree at HEAD before this work, NEW = same
program on the new library: its `encoder_auto`/`decode_auto` are plan + apply in one go), `tests/codec_plan_bench.bend`
(`./pb --threads N -- K T N`: `plan_ms` = `encoder_plan`, `enc1/enc2` = `encode_with_plan_auto` on two different source blocks with
the same plan, `dplan_ms` = `plan_for`, `dec1/dec2` = `decode_with_plan_auto` on two payloads with the same loss pattern) and
`tests/solver_bench.bend` modes 9/10. Milliseconds. Decode pattern: K symbols, 7/8 repair (as docs/benchmarks.md).

### Encoder setup (one source block)
| K | T | thr | OLD setup | NEW one-shot | plan (once per K) | block 1 with plan | block 2 with plan | speedup per extra block vs OLD |
|---|---|---|---|---|---|---|---|---|
| 1000 | 16 | 1 | 57 | 62 | 55 | 5 | 6 | 9.5x |
| 1000 | 16 | 12 | 59 | 54 | 55 | 6 | 7 | 8x |
| 1000 | 256 | 1 | 111 | 125 | 48 | 70 | 71 | 1.6x |
| 1000 | 256 | 12 | 71 | 92 | 51 | 38 | 23 | 3.1x |
| 1000 | 1024 | 1 | 289 | 330 | 49 | 267 | 308 | 1.0x |
| 1000 | 1024 | 12 | 102 | 109 | 50 | 48 | 54 | 1.9x |
| 4000 | 16 | 1 | 289 | 293 | 283 | 24 | 27 | 11x |
| 4000 | 16 | 12 | 322 | 292 | 283 | 25 | 28 | 11x |
| 4000 | 256 | 1 | 557 | 578 | 318 | 350 | 349 | 1.6x |
| 4000 | 256 | 12 | 420 | 364 | 312 | 70 | 77 | 5.5x |
| 4000 | 1024 | 1 | 1410 | 1689 | 309 | 1453 | 1621 | 0.9x |
| 4000 | 1024 | 12 | 607 | 509 | 314 | 245 | 287 | 2.1-2.5x |

### Decode (K symbols, 7/8 repair; includes re-encoding the K source symbols as before, ~85 ms per 1000 symbols at T=1024)
| K | T | thr | OLD decode | NEW one-shot | plan_for | decode 1 with plan | decode 2 with plan | decode 2 vs OLD |
|---|---|---|---|---|---|---|---|---|
| 1000 | 16 | 1 | 55 | 57 | 52 | 11 | 13 | 4.2x |
| 1000 | 16 | 12 | 60 | 60 | 50 | 16 | 21 | 2.9x |
| 1000 | 256 | 1 | 147 | 190 | 48 | 113 | 135 | 1.1x |
| 1000 | 256 | 12 | 141 | 156 | 53 | 94 | 115 | 1.2x |
| 1000 | 1024 | 1 | 415 | 511 | 46 | 407 | 514 | 0.8x |
| 1000 | 1024 | 12 | 337 | 314 | 58 | 253 | 264 | 1.3x |
| 4000 | 16 | 1 | 411 | 419 | 406 | 59 | 80 | 5.1x |
| 4000 | 16 | 12 | 430 | 407 | 377 | 60 | 74 | 5.8x |
| 4000 | 256 | 1 | 856 | 1038 | 376 | 678 | 786 | 1.1x |
| 4000 | 256 | 12 | 938 | 838 | 411 | 341 | 417 | 2.2x |
| 4000 | 1024 | 1 | 2362 | 3364 | 367 | 2763 | 3619 | 0.65x |
| 4000 | 1024 | 12 | 2135 | 2172 | 370 | 1731 | 2120 | 1.0x |

(Per-block "apply" figures include forcing one repair symbol, as tools/bench does; "decode with plan" includes the K re-encodings.)

### Reading the numbers
* The win is real where the plan is reused: encoder blocks of the same K cost only the symbol side (K=4000, T=16: 289 -> 25 ms,
  11x; T=1024 with 12 threads: 607 -> 245 ms). The decoder gains the same way when the loss pattern repeats (e.g. several
  payloads / sub-blocks with the same ESIs). At T=16 the plan IS the whole cost (plan ~ old solve), so the extra block is ~free.
* `plan_ms` is independent of T (49-55 ms at K=1000, ~283-314 at K=4000 for the encoder, ~370-410 for the decoder).
* Apply parallelises well (symbol slices share the plan): encoder block T=1024, K=4000: 1453 ms (1 thread) -> 245 ms (12 threads,
  5.9x), against 1410 -> 607 for the old one-shot slicing, because the slices no longer repeat the coefficient work.
* Cost of the split (honest): one-shot `solve_p` on ONE thread is slower for long symbols: +5-20 % at T=1024 encode, up to +40-50 %
  at T=1024 decode (K=4000: 2.36 s -> 3.36 s), parity at T=16, and with 12 threads one-shot is equal or faster (the old code
  repeated phase 1 in every slice). Measured split of the apply for K=4000, T=1024, 1 thread (encoder system): pivots + tail rows
  796 ms, tail solution 226 ms, forward substitution ~400 ms. Likely causes (not proven): every rhs symbol is fetched from an
  `Array` twice (pivot stage and phase 3), and `Array.get` of a `Data` element is a lazy dup that costs allocation per word; the
  old solver kept the rhs inside the row structs. The tail solve is the same number of symbol multiply-adds as before (n x m).
  Callers that solve a system exactly once at T >= 256 on one thread pay this.

## Gotchas
* A `Plan` must not contain an `Array` (linear Type, not duplicable): everything is lists; `apply` builds its arrays.
* The tail Gauss-Jordan reuses `dg_run_s` with the unit vectors as rhs "symbols" (width m octets); `sv_muladd` shape-matches
  `dst` first, so accumulators must be created with the right shape (`G.Vec.zeros(first rhs)`), never `VNil`.
* `Codec.received_rows` returns the received rows in REVERSE input order; `plan_for` reverses the ESIs first so row i = ESI i of
  the list you pass, which is also the order `decode_with_plan` expects its symbols in.
* `apply` trusts the rhs count (`plan_rows`); a wrong count aliases array slots silently (arrays wrap). The codec wrappers check
  it and return `None`; direct `Solver.apply` callers must.
* Dense (HDPC) row ids and leftover rows are the input row numbers, so rhs lookup is by row index; padding rows must be given
  zero symbols (the codec wrappers do).
* Bend: `+x : T <- IO.pure(..)` instead of `+x = ..` inside `do` blocks; definition order matters in test files too; `Nat` literals
  need `n` (`9n`) where `Nat` is expected.

## Update: apply on a flat symbol arena (docs/profile.md R3)
`Solver.apply` no longer touches `Vec` trees while it replays the plan. All symbols of one apply (the rhs rows, the pivot symbols
R_k, the tail rows R'_i, the solution C, one scratch symbol, and a 64K product table `T[(c << 8) | b] = c*b` when symbols have >= 8 words) live
in ONE `Array<U32>` (symbol s of a region at slot base + s * words); the pivot stage, the tail rows (= the dense-row correction),
the tail solution `C[col] = sum f R'_i`, and the forward substitution are tail-recursive loops over slices (`Flat.axpy/axset/scale`
in `src/flat.bend`, kernels as in `tools/profile/mb_arr.bend`). The plan is unchanged (lists only, duplicable); apply builds the
arena. The rhs rows are copied into the array once (this also removes the one-shot regression noted above: the old code fetched every rhs
symbol from an `Array<Vec>` twice, each fetch a lazy dup). `Solver.apply_arena(plan, rhs) -> Flat.Ar` returns the solved arena
(used by `Codec.decode*` to re-encode the K source symbols without converting to trees and back); `Solver.apply` reads the
arena out as `Vec`s. `apply_par` slices the Vec symbols exactly as before (each slice builds its own arena).
Words are multiplied by the table (4 lookups per word); symbols below `TAB_MIN()` = 8 words use the SWAR loop (the table costs
1.3 ms to build): `apply_arena`, K = 1000: T = 16: 2 ms (SWAR) vs 3 (table); T = 64: 6 vs 4; T = 128: 9 vs 6; T = 256: 16 vs 11;
T = 1024: 61 vs 35.

Measured (tools/bench-style harness `tests/codec_plan_bench.bend`, native, `--threads 1`, one A720 core pinned, ms; before = commit
97fdfba, after = this commit):
| K | T | plan | block with plan, before | after | decode with plan, before | after |
|---|---|---|---|---|---|---|
| 1000 | 1024 | 53 | 272 | 39 | 339 | 50 |
| 4000 | 1024 | 327 | 1484 | 179 | 2308 | 251 |
`tools/profile/bench_apply.bend` times the stages: K = 1000, T = 1024: `apply_arena` 33 ms (about 7.5M words of symbol arithmetic, 4.4 ns per
word including cache misses; the hot-cache microbenchmark is 2.9), the read-out of the 1071 solution symbols as `Vec`s 8 ms; K = 4000:
148 ms and ~40 ms. What is left of a one-shot solve is the plan (`plan_ms` above, T independent): phase 1 / normalisation 22 ms (K = 1000)
/ 121 ms (K = 4000) and 29 / ~180 ms of coefficient-side work on `Vec` trees (pivot coefficient vectors, dense-row correction, tail
Gauss-Jordan).

Later changes to the same code (Stage 2b / 2c): the coefficient side of `Solver.plan` (pivot coefficient vectors, leftover rows, dense-row correction, tail
Gauss-Jordan with unit vectors) also runs on a flat arena now (`p2.*`, docs/solver.md), plan K = 1000 / 4000: 52 -> 29, 333 -> 162 ms (T independent);
and `Solver.auto_depth` slices the symbols only for blocks of >= 2^23 words (the arena apply costs 4 ns/word, so 8 slices lose against their fork rounds;
12-thread numbers now equal 1-thread numbers at the benchmark sizes), `decode_auto` / `decode_with_plan_auto` take the arena path then.
Current one-shot numbers: docs/benchmarks.md.

## Update 2: the plan as a flat program, sliced apply as ONE parallel region, phase 1 on flat arrays (docs/scaling.md)
* **Flat program.** `Solver.prog(plan)` compiles a `Plan` into an `Array<U32>` of 3-word instructions (`kind + (c << 8)`, destination symbol,
  source symbol: copy / d ^= c*s / d = c*s / d = c*d / zero) in the order the list replay used (2 ms at K = 1000, 9 ms at K = 4000), and
  `Solver.apply` / `apply_arena` interpret it (`ip.*`): no list walk per apply. K = 1000, T = 1024, 1 thread: `apply` incl. read-out 45 -> 37 ms. Instruction mix of
  the K = 1000 encoder program (`tools/scaling/prog_stats.bend`): 33763 instructions = 2063 copies, 14695 xors (c = 1), 15934 multiply-adds, 79 sets, 992 scales;
  the multiply-adds are the 10 dense (HDPC) tail rows over all pivots (~9.9K) and the dense tail solution (79 x 79): about half of the symbol arithmetic.
* **Sliced apply.** `Solver.apply_par(d, plan, rhs)` clones the program per task (`Array.clone`; the plan's lists shared by all tasks were the scaling trap of the
  earlier slicing, docs/scaling.md G) and runs ONE fork tree of 2^d tasks: each builds its own arena from its word slice of every rhs symbol (the subtrees of the
  balanced `Vec` at depth d), replays the program, reads out; the slices are joined per symbol. `Solver.apply_ars` keeps the slice arenas (linear flat encoder,
  docs/codec.md); sliced decode re-encodes the source symbols inside each task. `Solver.auto_depth` now slices from 2^18 words of symbol data (was 2^23).
* **Flat phase 1.** `Solver.plan` runs phase 1 on one `Array<U32>` (docs/solver.md); the list version is `Solver.plan_ref` (test oracle, `tests/solver_plan_test.bend`).
  Plan K = 1000 / 4000 / 10000: 26 / 152 / 467 -> 10 / 57 / 179 ms (1 thread, rows built inside the clock).
* `Flat.table` is built by doubling (one read + one write per entry instead of a `G.mul`): 1.3 ms -> ~0.3 ms per table, which matters once every slice builds its own.
