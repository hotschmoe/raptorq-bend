# Profile: why the Bend codec is 13-110x slower than the Rust crate, and what pure Bend can reach

Scope: diagnosis only (no change to `src/`). The project stays pure Bend (no C/NEON effects, no non-Bend fallback), so the
question asked of every kernel is: what is the best *pure-Bend* implementation, and how far is it from C?
Everything here was measured on the benchmark box (12-core aarch64 cix, big.LITTLE; native binaries built with
`bend f.bend -o out`, system clang 14 first in `PATH`, IO `main`), on a scratch copy of the repo at commit e29b139.
Reproduce with `tools/profile/` (section 9).

Method notes: single-thread numbers are pinned (`taskset -c 10`, an A720 at 2.5 GHz) and are the minimum of 5 runs; other jobs
share the machine, so expect +-10-30 % noise (the C baselines moved by that much between runs). Ratios are what matter.
`ns/word` = per 4-octet U32 word of symbol data.

## 1. Verdict in four lines

1. The slowdown is the **symbol data layout**, not the language: a symbol is a balanced tree with one `VNode` + one `VWord`
   heap node per 4 octets and every operation is a non-tail recursive tree walk. That costs 16 ns/word for an XOR
   (C: 0.16-0.18) and 22-32 ns/word for a multiply-add. 92 % of a T = 1024 solve is spent in these operations (section 3).
2. The same kernels written with the idioms of the Bend authors' own benchmarks (flat `Array<U32>`, in-place writes, tail
   recursion, a 64K-entry product table in a second `Array<U32>`) run **at C scalar-table parity for multiply-add**
   (2.9 ns/word vs 2.76 for scalar C with the same table), parity for XOR at T = 16 (5x of auto-vectorised C and 3.6x faster than
   byte-wise C at T = 1024), 1.6-2.1x of scalar C for a whole dense Gauss-Jordan, and 5-9x of NEON C where SIMD matters. Replacing the tree by flat arrays is predicted to speed the T = 1024
   solve up 5-7x and repair generation 20-30x (section 8).
3. The "slower with 12 threads" anomaly is a **runtime code-generation effect**: the generated C has a fast path (`seq`) taken
   only when the process has exactly one worker thread; with `--threads` > 1 every non-tail call heap-allocates a continuation
   task instead of pushing a stack slot. A fork-free `Vec.xor` loop is 2.2x slower at `--threads 2` than at 1 (and patching the
   generated C so `seq` is always on restores the speed). Tail-recursive loops over arrays are not affected (section 6).
4. Where pure Bend cannot reach C it is for two reasons: no SIMD / no narrow types (XOR and multiply-add at NEON speed are
   5-9x away), and the `seq` issue above. Both are worth reporting upstream (draft text in section 7).

## 2. Cost sources, ranked (K = 4000, T = 1024 unless noted; 1 thread)

| # | Cost source | Evidence | Share |
|---|-------------|----------|-------|
| 1 | **Tree-of-words symbol per-word cost** (2 heap nodes = 24 B per word, CPS tree walk, shared-source refcount traffic) | `Vec.xor` hot in L1: 16 ns/word, flat array 0.9, C NEON 0.16 -> 100x vs C, 18x vs flat array. In the solver (cache cold) the same ops cost 26-50 ns/word (docs/perf.md: 70-100 in the largest cases) | replay 28 % + dense/leftover rows 30 % + tail GJ 15 % + phase 3 19 % = **92 %** of the 1401 ms solve at T = 1024; ~65 % at T = 16 |
| 2 | **Multiply kernel in the tree walk** (`mulw`: Nat-fuel SWAR loop, 8 xtime steps) | adds 6 ns/word on top of the 16 ns walk (xor 160 ms, muladd 230 ms per 10.2M words). Alternatives inside the *same* tree walk: unrolled SWAR 217, bit-sliced with hoisted k_i 198, log/exp 212 ms: only 9 % better because the walk dominates. Inside flat arrays the kernel matters: SWAR 8.6 ns/word, bit-sliced 4.2, 64K table 2.9 | part of #1; switching kernel alone is worth <= 10 % while the layout stays |
| 3 | **Repair generation = the same XOR walk on cold shared symbols** | 7016 XORs of 256 words per 1000 symbols (1.8M words) take 87 ms = 48 ns/word (3x the hot microbenchmark: cache misses on 24 B/word symbols + atomic refcount bumps on the shared intermediate symbols). Flat arrays: 3-4 ms (K = 1000 and 4000); Rust 1.5 / 2.0 ms; C NEON model 0.5 ms | 100 % of the repair stage |
| 4 | **Solver bookkeeping: row normalisation + phase 1** (lists of `Term`, `Array<Rw>`, weight buckets) | 13 ms + 13 ms (K = 1000), 52 + 53 ms (K = 4000), independent of T. Whole Rust cold solve at T = 16: 3.9 ms / 12 ms. A cons-list proxy (`mb_list`) runs at 7 ns per element-round, i.e. 2.4x *faster* than malloc/free C and 1.9x slower than arena C: this is our algorithm/passes (many walks, allocation), not a Bend deficit | 38 % of a T = 16 solve, 8 % at T = 1024 |
| 5 | **`--threads` > 1 loses the runtime's `seq` fast path** | tree-walk XOR 160 ms -> 349 ms (2.2x) at `--threads 2` and 12; repair 90 -> 125 ms; solver neutral (memory bound, +4 %) | explains the whole "13 threads slower" anomaly, section 6 |
| 6 | Sliced (`solve_auto`) intermediate symbols read ~30 % slower later | repair 125 ms (sequential solve) vs 165-177 ms (sliced solve), both at 12 threads; mechanism not isolated (not deferred work: second batch is as slow; not data origin per se: a microbenchmark with slice-built vectors shows nothing) | only visible after a sliced setup |
| 7 | Row construction (`C.fixed` + `source_rows`) | 3-9 ms (K = 1000), 12-46 ms (K = 4000) | 1-3 % |

Not a cause (each measured): compiler flags (`-mcpu=native`, LSE atomics, no outline atomics: no change on the generated C),
`Array.get/set` cost (see section 5), the SWAR multiply itself (#2), fork overhead (symbols are below the fork cutoff).

## 3. Phase breakdown of `Solver.solve_p` (1 thread, ms, solve only, cumulative stages differenced)

Measured by cutting the pipeline (`tools/profile/phases.bend`, a checksum forces each prefix; stage noise about +-5 ms):

| K, T | rows (build) | init (normalise, index) | phase 1 loop | log replay (`mat_pivs`) | leftover + dense-row correction | tail Gauss-Jordan | phase 3 | total |
|------|------|------|------|------|------|------|------|------|
| 1000, 16   | 3  | 13 (26 %) | 13 (26 %) | 5 (10 %)   | 13 (26 %) | 6 (12 %)   | ~0       | 50   |
| 1000, 1024 | 9  | 10 (3 %)  | 9 (3 %)   | 53 (19 %)  | 99 (35 %) | 62 (22 %)  | 53 (19 %) | 286  |
| 4000, 16   | 12 | 52 (19 %) | 53 (19 %) | 65 (24 %)  | 69 (25 %) | 34 (12 %)  | ~0       | 274  |
| 4000, 1024 | 46 | 49 (3 %)  | 66 (5 %)  | 386 (28 %) | 417 (30 %) | 212 (15 %) | 271 (19 %) | 1401 |

Reading it: at T = 1024 everything after phase 1 is symbol arithmetic (92-93 %) and scales with the symbol word cost; at
T = 16 the symbol work still takes 50-60 % because each logged elimination is one tiny tree walk (4 words = 66-127 ns per op
in the tree world vs 3.5-13 ns flat). Peak RSS (2 row builds included): K = 4000, T = 1024: 66 MB; the raw data is 4 MB.
Per-phase word rate estimates: replay 51 ns/word, dense correction 35, tail GJ 39, phase 3 26 (op counts from the algorithm in
`docs/solver.md`), against 16-22 ns/word hot: roughly 1.5-3x of cache-cold penalty on top of the walk cost.

## 4. Micro-benchmarks: data layout and operator cost

Same work in every row: 10.24M words of symbol data per measurement. `tools/profile/results/micro_results.txt` has the raw
lines. ns/word (T = 1024 = 256 words/op; T = 16 = 4 words/op in parentheses where it differs).

| Implementation | XOR | multiply-add (c varies) | notes |
|----------------|-----|--------------------------|-------|
| C, byte loop without SIMD (`-fno-tree-vectorize`) | 3.17 (2.50) | - | 1 byte per iteration |
| C scalar, gcc auto-vectorised | 0.18 (0.80) | table 2.76 (3.01), SWAR 4.51 (5.33) | table = 256-entry row, 4 lookups per word |
| C NEON (`vqtbl1q_u8` nibble tables) | 0.16 (0.80) | 0.38 (1.70) | upper reference |
| **Bend, current `Vec` tree** | **15.9 (16.6)** | **22.5 (31.7)** (`mulw` SWAR) | 100x / 60x C NEON |
| Bend tree, 4-word leaves | 4.0 | 10.9 (SWAR), 7.8 (bit-sliced) | |
| Bend tree, 16-word leaves | 1.3 | 7.5 (SWAR), 5.3 (bit-sliced) | public `Vec` type changes |
| **Bend flat `Array<U32>`** | **0.88 (3.5 ns/op)** | SWAR 8.6, bit-sliced 4.2 (5.0), **64K table 2.9 (3.2)** | best pure Bend |

Findings:

* **Flat array vs tree: 18x for XOR, 7.8x for multiply-add** (hot cache, 1 thread). The array is 4 B per slot (RSS check), the
  tree 24 B per word.
* **mulw (SWAR) vs table vs log/exp:** inside the tree all three are within 10 % (the walk dominates). On flat arrays the
  64K-entry product table `T[(c<<8)|b]` (a second `Array<U32>`, built once: 65536 `G.mul` = ms) is cheapest: 2.9 ns/word = scalar
  C table parity; bit-sliced SWAR with the eight `c*alpha^i` hoisted per call (`word_i = (w>>i)&0x01010101` times the byte
  constant, XOR of 8 terms) is 4.2; the current Nat-fuel SWAR loop is 8.6-9; per-octet log/exp via `G.mul` is as slow as SWAR.
  A 4-way unrolled word loop did not help in a first test (no gain; not pursued).
* **Per-op overhead** (T = 16): flat XOR 3.5 ns/op vs C 3.2 (parity); flat table muladd 12.9 vs C 12.0.
* **Dense Gauss-Jordan** n x (n+T) (all-pivots, same matrix, checksums equal to C): n = 142, T = 1024: C table 9.7 ms, C NEON 2.2,
  **Bend flat 20 ms** (2.1x / 9x); n = 79: 3.7 / 0.78 / 6 ms (1.6x / 7.7x); n = 142, T = 16: 1.6 / 0.50 / 3 ms. The current
  solver's tail Gauss-Jordan at K = 4000 (n = 142), T = 1024 takes 212 ms (10x slower than this kernel), K = 1000 (n = 79): 62 ms (10x).
* **Repair generation** (the real `C.lt_terms` term lists, 7.0-7.3 terms per symbol, one flat array of all intermediate symbols,
  fresh accumulator array per symbol, result checksummed): K = 1000/4000/10000, T = 1024, N = 1000: **3 / 4 / 4 ms** vs 87-130 ms
  now, Rust 1.5 / 2.0 / 2.5 ms, C NEON model 0.5 ms.

## 5. Arrays, lists, and what the Bend authors' benchmarks show

* `Array<U32>` `get`/`set` are O(1) native block operations: 1-2 ns per get+set at 2^8-2^16 slots (4 ns at 2^20, cache). An
  `Array` of boxed Data (`List<U32>`) costs 22-30 ns per get+set (allocation of the written value) and 4-6 ns per get. The
  statement in `docs/perf.md` section 5 ("Array ops are O(log n) path copies, ~1 us each at 2^16") does **not** reproduce on
  Bend 2.0.34 and should be corrected; `Array<Rw>`/`Array<VR>` in `solver.bend` cost tens of ns per access, not microseconds.
* Bend's own `bench/runtime` (bendlang/bend): the closest to our kernels is `editdist`, a DP over flat `Array<U32>` rows with
  Nat loop counters, a record of arrays (`type Dp is Type`) passed through stage defs that destructure `(a, x) = r` at the top of
  the next def. Built here (`-o`, `--threads 1`, 2^11 pairs): **Bend 0.52 s vs C twin 0.21 s (gcc -O3) / 0.26 s (clang -O3), 2.0-2.5x**
  of C for an array/word kernel, which is the same ratio our flat kernels show. `gameoflife` (U32 SWAR in registers, no memory):
  Bend 1.57 s vs its C twin 3.10 s (size 14), i.e. 2x *faster* than the twin. Their own M4 table shows the same picture
  (editdist 1.9 s sequential). The idioms that reach this: tail recursion with a `Nat` fuel (compiles to a loop), `Array<U32>` for any
  bulk word data, read-modify-write through one record of arrays, no `List`/tree in the hot path, `!` only for GPU/parallel
  batches (not usable here: no clang 19).
* Cons lists are not the problem: map-over-list proxy, 10M element-rounds: Bend 72 ms, C with malloc/free 175 ms, C with an arena
  37 ms.
* Limits found: `Array.new` requires a `Data` element type, so an `Array<Array<U32>>` cannot be created (use ONE flat array and
  index arithmetic: symbol c at offset c*stride, which is what the benchmarks above do); symbols per array must be a power of two
  slots (pad the stride; memory waste <= 2x); an `Array` is linear, so shared sources must be threaded through the loop and handed back.

## 6. The 12-thread repair anomaly (87 -> 161 ms at K = 1000, T = 1024)

Reproduced (`tools/profile/bench2.bend`: 87-94 ms at `--threads 1`; 126 at 2, 120 at 4, 129 at 12 with a sequential solve; 157-177
with the sliced `solve_auto`). Two separate effects:

**A. Thread count > 1 disables the runtime's single-lane fast path (about +40 % here, 2.2x on pure tree walks).** The generated C
has `work_loop(e, sp, t, seq)` with `seq = (pool_size == 1)` (`corpus_eval`). With `seq` set, a non-tail call pushes the
continuation id on the stack (`STK(0) = FID_..._K31; WL_PUSHN`). Without it, every non-tail call does
`task_node(e, FID_..._K31, WL_CONT, WL_IDX, 1)`: a heap allocation of a continuation task plus join counters
(`a32_sub_rel` on delivery) and `fid_nofk` checks. `Vec.xor`'s recursion makes one such continuation per tree node, 511 per
256-word symbol, with or without any fork. Experiments (all pinned to ONE core so no scheduling effect):
`mb_vec` XOR chain (no fork possible, 256 words): `--threads 1` 160 ms, `--threads 2` 349, `--threads 12` 350;
generated C patched to `work_loop(e, io_stk, t, 1)`, run with `--threads 2`: 171 ms. Same patch on the codec benchmark at
`--threads 12`: repair 123 -> 91 ms (= the `--threads 1` figure). Flat-array kernels (tail-recursive loops, no non-tail calls) show
no penalty: 9-10 ms at `--threads` 1, 2 and 12; the dense GJ and the cons-list loop likewise. Clang flags (`-mcpu=native`,
`-mno-outline-atomics -march=armv8.2-a`) change nothing.
This is also the true reason `docs/perf.md` found the old solver 20-60 % slower at 12 threads, in addition to the 0.3 ms
fork rounds.

**B. Sliced setup leaves intermediate symbols 30 % slower to read (125 -> 165 ms at 12 threads).** Sequential solve at 12 threads
vs `solve_auto` (d = 3): same `Codec.symbols` code, same threads; repeating the batch gives the same time (not deferred work), and
pinning every thread to one core keeps the gap (not cross-core cache transfers). A microbenchmark that builds a symbol out of 8
task-built slices (`VNode` join, like `vjoin`) reads as fast as a plain one, so the cause is something specific to the solver's
output (suspect: values aliased with the shared rhs input / refcount redirect cells). Not isolated; with flat arrays (R1 below)
the encoder never touches those trees, so it is moot.

## 7. What compiled Bend looks like for a hot loop (`bend f.bend -o x.c`)

* The emitted C is one CPS state machine (`work_loop`); each def is a segment; a self tail call is `WL_AGAIN`/`WL_JMP` (a real
  loop, no allocation, no stack growth): good. Arithmetic on U32 is inline C (`U32_BIN`), the SWAR `xtime4` is straight-line.
* Per `VNode` result: one `heap_alloc(cls_fit(2))`; per `VWord`: one more (1-word block); the old nodes are freed on the match.
  Allocation is a per-lane LIFO free list (3-4 instructions), cheap but not free: 2 allocations + 2 frees + 1 stack push/pop per
  word is the 16 ns of the tree XOR.
* A `+` (shared) argument costs atomics: every match of a shared node bumps the refcount of its children (`rfc_bump`, `a32_add`) and
  wraps them in redirect cells (`rfc_wrap`, one `heap_alloc(0)` per child on first visit). Symbols read many times (the
  intermediate symbols in the encoder, the pivot symbol in a muladd chain) pay this on every word.
* No allocation per element and no missing tail loop in the array kernels; each `Array.get` returns the array next to the value
  (a pair), which the compiler passes in registers/stack words, 1-2 ns.
* Build line used by `bend -o`: `clang -std=c11 -O3 x.c -lpthread -lm` (generic aarch64, no `-mcpu`).

### Draft upstream issues (bendlang/bend)

1. **Single-lane fast path only when `--threads 1`: every non-tail call heap-allocates a continuation task otherwise.**
   Program: a tail-free tree zip (`def xor(a: V, b: V)` recursing on both children, 256-leaf trees, 40000 iterations, no `!`, no parallel
   `let`). `bend f.bend -o f; ./f --threads 1`: 160 ms; `./f --threads 2`: 349 ms; `--threads 12`: 350 ms, one core pinned.
   Patching the emitted C `work_loop(e, io_stk, t, !BANGS && pool_size == 1)` -> `work_loop(e, io_stk, t, 1)` and running with
   `--threads 2` gives 171 ms, so the cost is the `task_node` continuations of the non-`seq` branch, not the work or contention.
   Request: choose stack vs heap continuations per call site (heap only for the children of a parallel `let`/`!` fork, or
   switch to stack continuations whenever the current task has no pending fork), so that sequential code does not pay for the
   existence of idle workers. Expected effect for us: 2x on recursive data-structure code at `--threads` > 1.
2. **No way to build an `Array<Array<U32>>`**: `Array.new` demands `Data` elements, arrays are `Type`. Request an `Array.init`
   (build from an index function/constructor) or `Array.new` for linear elements. Workaround: one flat array + index arithmetic.
3. **No SIMD or narrow integer types.** XOR over a flat `Array<U32>` is 0.88 ns/word vs 0.16 for NEON C (5.5x), table multiply-add
   2.9 vs 0.38 (7.6x). Request packed ops (U32x4 / U64 XOR, `Array` block xor/blend primitives that the C backend can
   auto-vectorise) or U8/U64 element types. Not fundamental to the runtime; a language-surface gap.
4. (docs) `Array.get/set` on `Array<U32>` is O(1) in the native backend; the guide could say which element types are unboxed (Array<U32>
   1-2 ns, boxed Data 22-76 ns per get+set).

## 8. Verdict per kernel (pure Bend vs C) and recommendations

C columns: scalar = word-wise table kernel (what a plain C port without SIMD writes); NEON = nibble `vqtbl1q_u8`, the upper
reference. "now" = the current tree implementation.

| Kernel | C scalar | C NEON | now (tree) | best pure Bend | vs C scalar | vs C NEON | limiting factor |
|--------|----------|--------|------------|----------------|-------------|-----------|-----------------|
| `xor` T = 1024 (per op) | 45 ns (auto-vec) / 812 (byte loop) | 42 ns | 4070 ns | 226 ns (flat array) | 5x / 0.28x | 5.4x | no SIMD / U8 (language); layout was ours |
| `xor` T = 16 (per op) | 3.2 ns | 3.2 | 66 | 3.5 | 1.1x | 1.1x | parity (loop overhead) |
| `muladd` T = 1024 (per op) | 707 ns (table) | 96.5 | 5760 | 740 (64K table) | 1.05x | 7.7x | no SIMD (language) |
| `muladd` T = 16 (per op) | 12.0 ns | 6.8 | 127 | 12.9 | 1.07x | 1.9x | parity with scalar |
| `scale` | like muladd minus one read | | like muladd | same kernel as muladd (not benchmarked separately) | ~1x | ~7x | as muladd |
| dense tail GJ n=142, T=1024 | 9.7 ms | 2.2 | 212 | 20 | 2.1x | 9x | idiom: stage-def record rebuild per element; no SIMD |
| dense tail GJ n=79, T=1024 | 3.7 ms | 0.78 | 62 | 6 | 1.6x | 7.7x | same |
| repair gen K=1000, T=1024, N=1000 | - | 0.51 ms (model) | 87 ms | 3 ms | - | 6x | no SIMD; vs Rust crate 1.5 ms: 2x |
| repair gen K=4000, T=1024 | - | ~0.5 | 111 | 4 | - | 8x | cache (L = 4157 symbols), vs Rust 2.0 ms: 2x |
| sparse row ops / phase 1 bookkeeping | C arena list map: 3.7 ns/elt-round | - | 13+13 ms (K=1000), 52+53 (K=4000) | proxy: 7.2 ns/elt-round, 1.9x of arena C, 2.4x faster than malloc C | ~2x | - | our algorithm (many list passes), not the language. No C twin of phase 1 exists; Rust cold solve at T = 16 is 3.9 / 12 ms for the whole solve |
| `Array.get/set` (U32) | ~0.3 ns | - | - | 1-2 ns | ~5x | - | runtime op per access (language) |

Bottom line for "can Bend be on par with C?" on this workload: **yes at scalar C level** for word kernels once the data is flat
(multiply-add 1.05x, XOR at 3.5 ns/op parity at small T, a whole Gauss-Jordan 2x, list-heavy bookkeeping 2x of arena C), **no at
SIMD level** (5-9x) because Bend has no SIMD/narrow types, and the tree-of-words layout we use today sits 60-100x away from C NEON,
which is nearly all of the 13-110x gap.

### Recommended optimizations (by payoff / effort; speedups are predictions scaled from the measurements above)

| # | Change | Effort | Predicted effect |
|---|--------|--------|------------------|
| R1 | **Repair generation on flat arrays**: after the solve, copy the L intermediate symbols once into one flat `Array<U32>` (stride = next power of two >= T/4) and generate symbols with the XOR loop of `mb_repair.bend` | small (isolated to `Codec.symbol(s)`, `C.encode_idx`; Vec -> array conversion at the boundary) | repair stage 87-130 ms -> 3-4 ms (**25-30x**; 2x of Rust instead of 58x); also fixes the 12-thread anomaly for this stage; decode's K re-encodings (about 8x the repair cost) gain the same factor |
| R2 | **Document `--threads 1` for everything except sliced solves**, and keep slicing off unless > 4 effective cores; after R3 slicing is not needed | trivial (docs) | removes the 40-120 % tree-walk penalty from the benchmarks table now |
| R3 | **Symbol arena for the solver**: all symbols (rhs, pivot rows, dense rows, tail matrix) in one flat `Array<U32>` threaded through the solver state; `muladd`/`xor`/`scale` become `(arena, dst, src, c)` loops with the 64K product table (threaded as a second array). Replay, dense-row correction, tail Gauss-Jordan and phase 3 all become array loops; the solver's list bookkeeping is unchanged | large (changes `Sym` in `gf256.bend`, `solver.bend`, `constraints.bend`, `raptorq.bend`; ownership must be linear; slices need `Array.clone` per task) | symbol phases (92 % of T = 1024) 8-15x faster. Totals: K = 1000, T = 1024: 286 -> 45-60 ms (**5-6x**, 7-9x of Rust cold instead of 42x); K = 4000: 1401 -> 200-280 ms (**5-7x**, 8-11x of Rust instead of 55x); K = 10000: 4.0 s -> 0.7-0.9 s (4.5-6x). T = 16: only 1.3-1.6x (bookkeeping dominates) |
| R4 | Cheaper intermediate step toward R3 if the `Vec` API must stay: 16-word leaves (`VW16{w0..w15}`) + bit-sliced hoisted multiply | medium (public `Vec` type changes, all Vec-shaped code in gf256/solver) | xor 16 -> 1.3 ns/word (12x), muladd 22.5 -> 5.3 (4x); totals 3-4x at T = 1024; keeps the persistent/shared semantics and slicing |
| R5 | Bit-sliced hoisted-`k_i` multiply in the current `Vec.muladd` (compute `c*alpha^i` once per call) | tiny | 1.1x on muladd while the tree stays (198 vs 217 ms), 2x with flat arrays; log/exp and unrolled SWAR give nothing |
| R6 | Bookkeeping (init + phase 1): fewer list passes, flat `Array<U32>` CSR rows for columns/weights | large | at most 2-3x on the 38 % (T = 16) / 8 % (T = 1024) share: 1.2-1.3x total at T = 16, ~1.05x at T = 1024; do after R3 |
| R7 | Upstream issues (section 7): per-call `seq` fast path, `Array.init` for linear elements, SIMD/narrow types | external | 2x on recursive code at `--threads` > 1; would make R3's parallel slicing worthwhile again |

After R1 + R3 the remaining gap to the Rust crate is expected at about 7-11x for T = 1024 (SIMD, plan caching) and 8-15x for
T = 16 (bookkeeping), instead of 13-110x.

## 9. Reproducing (everything under `tools/profile/`)

```
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1
tools/profile/run_micro.sh 5 > tools/profile/results/micro_results.txt     # section 4/5/6 numbers, 1 min, builds into build/profile/
tools/profile/mk_phases.sh && tools/profile/run_phases.sh build/profile/phases "1000 4000" "16 1024" 5   # section 3, 3 min
bend tools/profile/bench2.bend -o build/profile/bench2 && ./build/profile/bench2 --threads 12 -- 1000 1024 1000 <0|1>  # section 6 (4th arg: 0 sliced, 1 sequential solve)
```

Files: `mb_vec.bend` (tree `Vec` xor/muladd), `mb_mulw.bend` (kernel variants in the tree walk), `gen_mb_leaf.py` (M-word leaves,
generates `mb_leaf_<M>_<kernel>.bend`), `mb_arr.bend` (flat-array xor / SWAR / bit-sliced / 64K table), `mb_gj.{bend,c}` (dense GJ,
checksums must agree), `mb_repair.bend` (repair generation with the real term lists), `mb_list.{bend,c}` (list-bookkeeping proxy),
`mb_arrops.bend` (Array.get/set cost), `mb_c.c` (C scalar/NEON baselines), `phases.bend` + `solver_cut_append.bend` +
`mk_phases.sh` + `run_phases.sh` (phase breakdown; the harness is appended to a private copy of `solver.bend` written against
commit e29b139, the real file is untouched), `bench2.bend` (codec benchmark with a solver-mode switch and a second repair batch),
`rss.py`. The scalar-C numbers use gcc -O3 (Debian 12); the Bend side is the same binary-building flow as the rest of the repo.
