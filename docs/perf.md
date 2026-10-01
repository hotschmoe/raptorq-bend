# Performance notes (solver, GF(256) symbols, threading)

> Historic document for the tree-symbol (`G.Vec` per word) solver. Since `docs/profile.md` R1/R3 (flat `Array<U32>` symbol arena in
> `Solver.apply`, flat coefficient arena in `Solver.plan`, flat repair generation, `src/flat.bend`) the numbers and the threading conclusions
> below no longer describe the code: see `docs/plan_apply.md` (update) and `docs/benchmarks.md` for the current ones. Section 5's
> `Array` remark has been corrected; the measurements and diagnoses of sections 1-4 stay valid for the tree solver.

Machine: 12-core aarch64 (cix), 30 GB; native binaries (`bend f.bend -o out`, system clang first in `PATH`), always an
IO `main` (a non-IO `main` uses a much slower evaluator). Harness: `tests/solver_bench.bend`
(`./sb [--threads N] -- <K> <mode> [<T octets> [<d>]]`; mode 5 = timed inactivation solve, 3 = tail size, 0 = solve + verify by
re-encoding every source symbol, 8 = `Solver.solve_auto`). All times are the SOLVE only (row construction is 4 ms at K=1000,
190 ms at K'=56403 and is subtracted; the harness builds the rows twice and subtracts the first build).

## 1. Before / after

"before" = the solver at commit 19ab7d5 (full pass over all rows per pivot, dense rows kept as full-width vectors, dense tail
carried through phase 1), "after" = this work. `--threads 1`, T = 16 octets (so this is almost pure coefficient work):

| K (L)          | tail n before -> after | before   | after    | speedup |
|----------------|------------------------|----------|----------|---------|
| 100 (128)      | 36 -> -                | 11 ms    | 4 ms     | 3x      |
| 500 (558)      | 102 -> -               | 0.185 s  | 0.024 s  | 8x      |
| 1000 (1071)    | 155 -> 79              | 0.57 s   | 0.053 s  | 11x     |
| 2000 (2099)    | -                      | 2.27 s   | 0.12 s   | 19x     |
| 4000 (4157)    | 436 -> 142             | 8.3 s    | 0.28 s   | 30x     |
| 10000 (10269)  | - -> 218               | 56.7 s   | 0.91 s   | 62x     |
| 20000 (20565)  | - -> 317               | (~3-4 min, extrapolated) | 2.7 s | -  |
| 56403 (57326)  | - -> 604               | (hours)  | 14.7 s   | -       |

(K = 1000: the 0.2 s target is met 4x over; K = 10000 solves in under a second; the full K' = 56403 system (L = 57326,
57326 rows) solves in 15 s at T = 16 and 36 s at T = 1024 on one thread, peak RSS 288 MB / 942 MB.) Scaling is now about
L^1.5 (K=4000 -> 10000: x3.3 for x2.5 in K).

Longer symbols, solve only. `thr1` = `--threads 1`, `thr12` = `--threads 12` with plain `solve_p`, `thr12 d=3` = `--threads 12`
with `Solver.solve_par(.., d = 3)` (8 symbol slices solved concurrently):

| K, T (octets) | before thr1 | before thr12 | after thr1 | after thr12 | after thr12 d=3 | d=3 vs thr1 |
|---------------|-------------|--------------|------------|-------------|-----------------|-------------|
| 1000, 16      | 567 ms      | 678 ms       | 53 ms      | 50 ms       | 52 ms           | 1.0x        |
| 1000, 256     | 745 ms      | 892 ms       | 108 ms     | 110 ms      | 71 ms           | 1.5x        |
| 1000, 1024    | 1238 ms     | 1385 ms      | 291 ms     | 303 ms      | 101 ms          | 2.9x        |
| 1000, 4096    | 3265 ms     | 3626 ms      | 1105 ms    | 1177 ms     | 316 ms          | 3.5x        |
| 4000, 16      | 8349 ms     | 9144 ms      | 282 ms     | 275 ms      | 279 ms          | 1.0x        |
| 4000, 256     | 9975 ms     | 10421 ms     | 543 ms     | 549 ms      | 394 ms          | 1.4x        |
| 4000, 1024    | 13594 ms    | 14240 ms     | 1447 ms    | 1417 ms     | 595 ms          | 2.4x        |
| 4000, 4096    | -           | -            | 5194 ms    | 5339 ms     | 1740 ms         | 3.0x        |
| 10000, 16     | 56.7 s      | -            | 913 ms     | 976 ms      | 1131 ms         | 0.8x        |
| 10000, 256    | -           | -            | 1736 ms    | 1680 ms     | 1545 ms         | 1.1x        |
| 10000, 1024   | -           | -            | 4017 ms    | 3969 ms     | 2103 ms         | 1.9x        |
| 10000, 4096   | -           | -            | 14274 ms   | 13966 ms    | 5245 ms         | 2.7x        |
| 56403, 256    | -           | -            | 19.8 s     | -           | 21.3 s          | 0.93x       |
| 56403, 1024   | -           | -            | 35.9 s     | -           | 24.2 s (2.8 GB) | 1.5x        |

* The old solver was 20-60 % SLOWER with 12 threads than with 1 (every row above); the new one is neutral without slicing
  (`thr12` == `thr1` within noise) and 1.5-3.5x faster with `solve_par` once the symbols are >= 256 octets.
* Slicing does not help (or hurts, 0.8-0.93x) where the symbol-independent coefficient work dominates (small T, or K'=56403
  with T <= 256): every slice repeats it, so the 8 concurrent copies slow each other down (memory traffic: +35 % at K=10000).
  `Solver.solve_auto` therefore slices only for symbols of >= 64 words (256 octets) and with d = min(3, log2 threads).
* d = 4 (16 tasks on 12 threads) is slower than d = 3 (K=10000, T=1024: 3.6 s vs 2.0 s): the runtime deals every task to a
  core once and never moves it, so 12 + 4 tasks finish in two waves.
* A parallel process pays ~25-30 ms once (thread pool start: 12 x 2 GiB stack mappings); visible at K=1000.

Where the time goes now (`--threads 1`, solve only; phase 1 + materialisation of the pivot rows, then dense-row correction and
leftover rows, then dense Gauss-Jordan over the tail, then the forward substitution), measured by cutting the pipeline:

| K, T          | phase 1 + pivot rows | leftover + dense rows | tail Gauss-Jordan | phase 3 | total  |
|---------------|----------------------|-----------------------|-------------------|---------|--------|
| 10000, 16     | 0.62 s               | 0.21 s                | 0.12 s            | ~0 s    | 0.92 s |
| 10000, 1024   | 2.18 s               | 0.44 s                | 0.50 s            | 0.83 s  | 3.94 s |
| 56403, 16     | 9.4 s (phase 1: 3.0) | 3.2 s                 | 1.6 s             | 0.5 s   | 14.7 s |

Phase 1 proper (pivot search, inactivation, logs) is 0.37 s at K=10000 and 3 s at K'=56403. The rest of the first column is the
"materialisation" of the pivot rows from their elimination logs (one packed-coefficient xor + one symbol xor per logged
elimination, about 6.4 per pivot). The 3.2 s at K'=56403 are the 10 dense HDPC rows corrected for 57k pivots (10 x 57k
GF(256) multiply-adds of 151 words).

## 2. What changed in the algorithm (all in `src/solver.bend`)

1. **Column -> rows index + weight buckets.** Rows are in an `Array`, `ci[col]` lists the rows that have `col` in their active
   part (it only ever shrinks: pivot rows only contain their own pivot column and columns that get inactivated, so the
   active part never fills in), and rows are bucketed by active weight with lazy deletion. A pivot step touches only the rows in
   the lists of the pivot column and of the inactivated columns (about 6 per step) instead of all rows.
2. **Sparse LT rows stay sparse.** The old code turned every row with more than 16 terms into a full-width dense vector; in
   RaptorQ 14 % of the LT rows have degree 40+. Now only rows with > 48 terms covering > l/4 columns are dense (the H HDPC rows).
   This also shrinks the dense tail a lot (K=1000: 155 -> 79 columns, K=4000: 436 -> 142) because those rows can be pivots.
3. **Phase 1 does not touch symbols or inactive coefficients.** Each row records a log `(g, j)` = "row += g * pivot row j".
   After phase 1 the inactive coefficient vectors (packed 4 octets/word over the tail columns) and the rhs symbols are
   computed from the logs, in pivot order. Inactive terms are keyed by *inactivation position* so they are consed on (no list merge)
   and packing a row needs no walk over the tail columns.
4. **Dense rows are corrected once at the end** with packed word operations (`row -= g_k * pivot row k` for every pivot; `g_k` is
   the original coefficient at the pivot column over the pivot's coefficient, because pivot rows contain no other pivot column).
5. **Phase 3 by forward substitution through the original sparse rows** (RFC phase 5): pivot k's original equation only mentions
   earlier pivot columns, inactive columns and its own column. This replaces the old per-pivot dense back-substitution.
6. `Vec.xor/muladd/scale/zeros/build` (gf256) fork only above 4096 words; `st_build`/`dg_find` of the solver are sequential.

Tried and not kept:

* *Pivot column choice by degree* (inactivate the highest- or lowest-degree columns of the chosen row instead of "all but the
  first"): tail 76/146/221/320 (max degree) and 75/151/223/328 (min degree) vs 79/142/218/317 for K = 1000/4000/10000/20000: no gain.
* *RFC 5.4.2 graph-component rule* (r = 2: pick the weight-2 row in the largest component of the column graph; r != 2: min original
  degree). Not implemented in Bend. A Python simulation of phase 1 on the real K = 1000/4000/10000 systems
  (dense rows ignored, same removal logic) gives tails 67/129/200 for the rule against 71/134/222 for the LIFO row choice we use
  and 72-73/138-144/214-224 for other tie-breaks: 4-10 % smaller tail, which is about the spread caused by tie-breaking alone, and
  the tail Gauss-Jordan is 13 % of the time at K=10000, so the effect on runtime would be a few percent. Cheap proxies (best of
  the first 4/16/64 candidates by column degree) do not reproduce it. The exact rule needs a union-find over the weight-2 rows at
  every step.
* *Forking each pass over the row tree* (`PAR() > 0`, the old design, kept for the tail Gauss-Jordan): K=20000 T=256 12 threads
  6.3 s vs 4.9 s with 1 thread; K'=56403 T=1024 37.3 s vs 38.6 s (3 %). Passes carry 1-6 ms of work, a parallel region costs ~0.3 ms.
  `PAR()` is 0.

## 3. Why parallel runs did not scale (diagnosis)

The generated C runtime executes parallel work in bulk-synchronous rounds (`pool_turn` in the emitted C: a grow pass that expands
the fork frontier and a drain pass in which every lane runs its tasks, each round entered and left through a mutex + condition
variable broadcast to all worker threads). Consequences, each measured with the micro-benchmarks below:

1. **A parallel region reached from sequential code costs ~0.3 ms** (2 rounds), independent of the work in it. 2000 sequential
   `Vec.muladd`s on a 4096-word vector: 212 ms at 1 thread, 540-660 ms at 2-12 threads (64 tasks of 64 words, each op a
   round). 1024 rows x 200 passes of 256-word muladds in a sequential loop, with a 64-word cutoff (4 tasks per op): 1.2 s at 1
   thread, **71 s** at 12 threads (~0.35 ms per op); the old gf256 forked at every tree node (2000 muladds of 4 words: 1 ms at 1
   thread, 575 ms at 12).
2. **Forks inside an already-running task are free** (drained tasks run their forks inline), so the same muladds inside a
   row-parallel region are fine. Parallelism therefore has to be coarse and outermost.
3. **The old solver forked all the time from sequential code**: `Vec.xor/muladd/scale` per tree node (inside every row update),
   `Vec.from_list` per node (every symbol construction), `st_build`/`dg_find` per node, and one row-tree pass (a region) per pivot
   step carrying a few microseconds of work. Hundreds to thousands of 0.3 ms rounds explain the 0-60 % slowdown at 12 threads.
   `PAR=0` did not help because the Vec ops and `from_list` still forked.
4. **Work imbalance is not the issue; task count is.** Independent long tasks scale: 2^4 tasks x 100k muladds of 64 words: 4449 ms
   (1 thread) -> 582 ms (12 threads) = 7.6x (the 12 "cores" are not equal); 2^3 tasks 2321 -> 324 ms. Few huge tasks are bad:
   splitting one 262144-word muladd into 4 tasks was 2.5x SLOWER than sequential, into 64 tasks 2.2x faster. 16 tasks on 12
   threads are slower than 8 (two waves).
5. **Sharing / affine copying is not the problem.** `+` values are reference counted, never copied; reading a shared node costs
   atomic increments, not allocation. Tree-parallel map of 4096 rows x 256 words over a shared `+` pivot symbol scales 4.5x
   (1211 -> 268 ms for 50 rounds) once each round carries >= 5 ms of work. Copying the pivot symbol per task (the old `vcopy`) was
   slower, not faster.
6. Real remaining limits: (a) the greedy pivot search and the elimination-log chain are inherently sequential (Amdahl), (b) 8 concurrent
   copies of the symbol-independent work slow each other down (+35 %, memory bound), (c) rows/symbols are 24-40 bytes per word in Bend
   (VNode + VWord per word), so everything is allocation/cache bound: 70-100 ns per symbol word in the large cases against 25 ns in
   a tight micro-benchmark.

Micro-benchmarks (scratch files, not committed): chain of N `Vec.muladd` on one vector (`vb`), tree-parallel map over rows with a
shared pivot symbol (`vb2`), 2^d independent chains (`vb3`).

## 4. How parallelism is used now

`Solver.solve_par(l, p, d, rows)`: the symbols of a system are independent, so every rhs is cut into 2^d word ranges (the
subtrees at depth d of the balanced `Vec`: no copying) and the 2^d slice systems are solved as 2^d independent top-level tasks;
`VNode{..}` of the slice results has exactly the shape `Vec.from_list` builds, so the joined C is identical. One parallel
region of seconds, no synchronisation inside. Every slice redoes the symbol-independent work (pivot search, coefficient vectors,
tail elimination), which is why it is opt-in (`solve_p` stays sequential and `--threads`-neutral) and why the speedup is limited to
`(t_coeff + t_sym) / (t_coeff + t_sym / 2^d)` with a contention penalty on t_coeff. `Solver.solve_auto(l, p, rows) : IO` picks d
from `IO.thread_count()` and the symbol size.

Ideas not done: share phase 1 between slices (saves CPU and memory, not wall time); parallel reduce for the dense-row correction
(3.2 s of 14.7 s at K'=56403; only useful outside slicing); a wider-leaf `Vec` (4-8 words per node) would cut allocation per symbol
word by 4-8x for all symbol work but changes the public `Vec` type.

## 5. Gotchas for Bend performance (new)

* A fork reached by sequential code is a runtime round (~0.3 ms with 12 threads). Never fork below ~a millisecond of work; forks
  inside a task are free. `l r = f(..) g(..)` is a fork; `l = f(..)` then `r = g(..)` is not.
* `Array` ops: the Base source (`Array.get/set` = a descent through `ANode`/`ALeaf` with `Array.size` each time) is what the interpreter
  runs and reads like O(log n) path copies at ~1 us each, but in a NATIVE binary (`-o`) they are O(1) block operations (docs/profile.md
  section 5, measured): `Array<U32>` get+set 1-2 ns at 2^8-2^16 slots (4 ns at 2^20, cache), `Array<Data>` of boxed elements (`List`, `Vec`,
  `Rw`) 4-6 ns per get and 22-30 ns per set (the written value is allocated), still far from microseconds. Correction of an earlier
  version of this note. Bulk word data therefore belongs in ONE flat `Array<U32>` (`src/flat.bend`); the arrays of `Rw`/`VR` records of
  phase 1 are fine for bookkeeping. They are the right tool for O(1)-ish state (rows by id, column index).
* `Array` indices WRAP (`i & (n-1)`): an out-of-range bucket index silently aliases another bucket (bug found and fixed here).
* A `let`-bound value cannot be scrutinised by `match`, and match scrutinees must follow the parameter order; use helper defs, tuple
  patterns on parameters (`case 1n+q Tuple{a, b}:` matches a `A & B` parameter) and nested constructor patterns
  (`case Lg{+g, j} <> t Tuple{ar, x}:`; a variable bound by a multi-scrutinee `case` cannot be matched again).
* No mutual recursion also forbids `helper -> loop` and `loop -> helper -> loop` chains: a loop that needs the result of an
  `Array.get` must take the get result as a parameter (prefetch pattern: the caller passes `Array.get(..)` for the NEXT element).
* `(a, b) = f(..)` destructuring then a call is fine, `Nat` fuel can be huge (`1000000000n`) because it is a machine number.
