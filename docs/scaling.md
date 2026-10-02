# Scaling lab: what pure Bend 2.0.34 scales on this machine, and what that buys one RaptorQ block

Everything here is pure Bend (no foreign code), Bend 2.0.34, native binaries (`bend f.bend -o out`, system clang 14 first in PATH unless noted), IO `main`.
Harnesses (all under `tools/scaling/`): `lab.bend` (one binary, many patterns, the mode is the first argument), `sweep.py` (min of 5 runs at 1/2/4/8/12
threads, prints ms and speedup), `run_all.sh` (the whole E1 table; raw output in `results.txt`), `lab_bang.bend` (the `!` variants), `apply_par.bend`,
`plan_ab.bend`, `plan_stages.bend`, `phase1_time.bend`, `dplan.bend`, `prog_stats.bend` (E2/E3 experiments), `quietcore.sh`, `bench_min.sh`.
Codec numbers come from `tools/bench/bench.bend` / `tools/bench/run.sh` (docs/benchmarks.md).

## The machine, and how honest the numbers can be

* 12 cores, **not equal** (`/sys/devices/system/cpu/cpu*/cpu_capacity`): cpu0,1 Cortex-A720 @2.6 GHz (capacity 1024), cpu10,11 A720 @2.5 (984), cpu6,7 A720 @2.3 (905),
  cpu8,9 A720 @2.2 (866), **cpu2-5 Cortex-A520 @1.8 GHz (capacity 279)**. Measured: the same 4-thread job takes 15-18 ms on four A720 and 49-97 ms on the
  four A520: a little core is ~3-4x slower. 8 big + 4 little cores are worth about 8.4 big cores at best, and the runtime deals each task to one thread once
  (never moves it), so a static split over 12 threads is gated by the slowest core.
* Methodology: rows with `t <= 8` threads are confined to the 8 big cores (`taskset -c 0,1,6,7,8,9,10,11`), `t = 1` is pinned to the least busy big core
  (`quietcore.sh`; the 1-thread rows of the codec tables are all on cpu0, the fastest), `t = 12` is unpinned. Min of 5 (lab) / 3-7 (codec) runs. The 1-thread
  baseline runs on a faster core than some of the 2-8 thread runs (2.6 vs 2.2-2.5 GHz): speedups are understated by up to ~15 %.
* **The box was shared.** For the first half of this work a kernel build (`make -j11`, another user) kept the load average at 13-20 on the 12 cores; the lab table was
  re-run when it dropped to 1-3 (the tables below are from the quiet runs; the first, loaded run of the same patterns gave 3-4x at 8 threads instead of 6.5x and
  forks-from-sequential-code costing 0.5-1 ms instead of 0.15 ms per round). Other agents' benchmarks also used cpu10: an early sweep with a contended 1-thread core
  produced "speedups" of 10-14x at 8 threads (impossible: 8 big cores) and was discarded; `sweep.py` now picks the quietest core. Single-thread numbers are good to
  about +-5-10 %, multi-thread to about +-15 %.

## E1. Results (speedup vs 1 thread, quiet box, load 1-3; ms in `tools/scaling/results.txt`)

| pattern | x2 | x4 | x8 | x12 | note |
|---|---|---|---|---|---|
| A. balanced fork tree, every leaf allocates its own `Array<U32>` and runs a tail-recursive read-modify-write kernel; leaf ~1 us (2^19 leaves) | 1.9 | 3.6 | 6.6 | 7.0 | |
| same, leaf ~10 us (2^16 leaves) | 1.9 | 3.7 | 6.5 | 6.9 | |
| same, leaf ~100 us (2^13) | 1.9 | 3.7 | 6.6 | 7.0 | |
| same, leaf ~1 ms (2^10) | 2.0 | 3.7 | 6.6 | 7.0 | |
| same, leaf ~10 ms (2^6) | 2.0 | 3.7 | 6.7 | 6.6 | |
| B. only 8-512 leaves of ~100 us (total work 80-110 ms: thread start + imbalance visible) | 1.7-1.9 | 2.9-3.3 | 4.5-5.5 | 2.9-3.4 | 8 leaves on 12 threads: the A520 gate it |
| C. **forks reached from sequential code**: 500 rounds of an 8-leaf tree, 85 us leaves | 1.3 | 2.0 | 2.6 | 1.4 | |
| same, 5000 rounds, 10 us leaves | 0.38 | 0.43 | 0.43 | 0.24 | one round costs 0.15 (8 thr) - 0.3 ms (12 thr) |
| same, 20000 rounds, 4 us leaves | 0.05 | 0.06 | 0.05 | 0.03 | |
| C'. the same work as ONE region (leaves loop 500 / 5000 / 20000 times) | 1.9 / 2.0 / 1.8 | 3.4 / 3.5 / 3.1 | 6.2 / 6.1 / 5.6 | 6.0 / 5.8 / 4.9 | |
| D. non-tail leaf recursion in the tree (hash-chain sum) / tail loop | 1.9 / 1.7 | 3.1 / 2.8 | 5.1 / 4.8 | 4.7 / 4.8 | both scale; non-tail is 2.4x slower in absolute terms |
| D'. sequential non-tail walk that allocates nodes (`Vec.xor` shape), NO fork in the def | 1.0 | 1.0 | 1.0 | 1.0 | 74 ms at every thread count |
| D''. **same walk, the def also contains a fork branch that is never taken** (`G.Vec.xor.go` shape) | **0.48** | 0.48 | 0.47 | 0.48 | 83 ms at 1 thread, 174 at >= 2 |
| D'''. same, the fork-free branch moved into a **separate twin def** | 0.97 | 0.97 | 0.97 | 0.99 | penalty gone (73-75 ms) |
| E. ONE array cut by `match a: case ANode{l, r}` into 2^13 slices of 4096 words, fork tree over them, re-joined with `ANode{x, y}` | 1.6 | 2.5 | 3.1 | 3.3 | memory bound (128 MB array); same work as a tree of leaf arrays: 1.9 / 3.5 / 6.0 / 5.9 |
| E'. same, 2^6 slices of 16K words (10 ms of work each): ANode / leaf-array tree / own arrays | 1.9 / 1.9 / 1.9 | 3.6 / 3.6 / 3.6 | 6.1 / 6.4 / 6.4 | 6.4 / 6.6 / 6.9 | no difference |
| E''. slice count at EQUAL work (1 thread): 1 / 2^6 / 2^10 / 2^14 / 2^16 / 2^18 slices | | | | | 212 / 210 / 217 / 247 / 273 / 827 ms: a slice costs ~2 us, free down to 16 words |
| F. repair-generation shape: ONE shared read-only array through `Array.fork`, each leaf XORs a few symbols of it into its own output array (16 / 78 / 83 ms of work) | 1.6 / 1.7 / 2.3 | 2.7 / 2.9 / 4.0 | 4.0 / 4.6 / 7.6 | 5.3 / 4.9 / 6.9 | |
| G. a `Data` list (Solver.Plan-shaped, 16K elements) **shared** by all 16 leaves, each walks it 300 times | 1.9 | 2.5 | 3.5 | 3.9 | atomic refcount traffic on shared nodes |
| G'. same, every leaf builds its **own** copy | 2.0 | 3.8 | 6.6 | 7.4 | |
| serial control: 8192 leaf kernels in a plain loop, `--threads` 1/2/4/8/12 | 1.0 | 1.0 | 1.0 | 1.0 | tail loops over arrays do not care about `--threads` |

(Ideal for 2 / 4 / 8 / 12 threads on this machine: 2 / 4 / 8 / ~8.4 big-core equivalents.)

## What the lab says (rules of thumb)

1. **Pure Bend scales, on exactly one shape**: one top-level `a b = f(..) g(..)` tree (a balanced divide and conquer), the leaves are tail-recursive loops over
   `Array<U32>` that the *leaf allocates itself*, no sharing between leaves: 6.5-7x at 8 threads, down to leaves of ~1 us (a task costs tens of nanoseconds; the cost
   that matters is a *region*, rule 3). Leaf size is not critical: >= 10 us keeps the task overhead below 1 %. 2^3 - 2^6 tasks are enough; more tasks than
   threads (16 on 12) lose to a second wave; with only 8 coarse tasks `--threads 12` is *worse* than 8 because the tasks that land on the A520 cores gate the join.
2. **big.LITTLE is a scheduling cliff for static trees**: tasks are never moved, the A520 are 3-4x slower. For coarse trees use `--threads 8` pinned to the big cores
   (`taskset`); fine-grained trees (>= 2^10 leaves) do not mind. Runtime limit (no work stealing), not something the program can fix.
3. **A parallel region reached from sequential code costs 0.15-0.3 ms** and grows with the thread count: a loop that forks per iteration is 0.4-0.03x of sequential (C).
   One region around the whole computation scales like A (C'). Fork once, outermost; a single block can use only ONE region per phase that has >> 1 ms of work.
4. **Non-tail recursion is free at any `--threads` when the def contains no fork; a def that merely *contains* a parallel `let` makes all its non-tail calls
   heap-allocate continuation tasks at `--threads` > 1 (2.1x slower), even in the branch that never forks** (D'' vs D'''). The fork-free recursion goes into its own twin
   def. (The precise form of the `seq` finding of docs/profile.md section 6; `G.Vec.xor/muladd/zeros/scale` pay it at `--threads` > 1: their `fk = 0` branch should call a twin.)
   Also found: **a program that contains a single `!` call is compiled without the single-thread fast path for ALL its code** (the emitted C has `work_loop(.., !BANGS && pool_size == 1)`):
   `lab_bang.bend`'s plain modes run ~10 % slower at `--threads 1` than the same code in `lab.bend`. That is why `lab.bend` is bang-free.
5. **Disjoint slices of one array are free**: `match a: case ANode{l, r}` hands out the two halves with no copy (~2 us per slice at any size, indices are relative to the
   slice), `ANode{x, y}` joins them; lengths are powers of two. A tree of leaf arrays built inside the tasks is as fast. No chunking primitive is needed.
6. **Read-only sharing**: `Array.fork(U32, a)` (an `@unsafe` Base def) gives two handles of ONE array in O(1) and is correct and fast from several tasks (F), **but
   `scripts/check_proofs.sh` rejects any def that reaches an `@unsafe` def** ("N defs rely on unsafe or foreign code"), so the codec uses `Array.clone` (a 0.1-0.5 ms copy per
   task for the 0.4-1.6 MB program). **Sharing a `Data` structure (a list, e.g. `Solver.Plan`) between tasks is a scaling trap** (G vs G'): every match bumps refcounts
   atomically on nodes all tasks touch (3.5x vs 6.6x at 8 threads), and a list walk costs ~18 ns per element against ~1 ns per array slot. Shared inputs belong in flat arrays.
7. A task's own allocation is cheap (`Array.new` inside the leaf, tree-of-nodes building inside the leaf): allocation is per-lane.

## H. `f!(..)` (bang) and clang 19 vs 14 (quiet box)

Built with `clang` 19.1.7 first in PATH (`PATH="$HOME/.bend/bin:<dir with clang -> /usr/bin/clang-19>:/usr/bin:/bin"`, `tools/bench/run.sh` takes `CLANG_DIR=`), run with
`--gpu off --threads N` (no GPU here: a bang runs on the CPU pool).

* **A bang is exactly a plain fork on the CPU.** `lab_bang.bend` modes 20-25 vs 0, 1, 2, 5, 6 (speedup at 2 / 4 / 8 / 12 threads, clang 14): balanced tree 1.9 / 3.6 / 6.3 / 6.6 banged vs
  2.2 / 4.2 / 7.5 / 7.6 plain (both without the `seq` fast path in that binary: the 1-thread baseline differs by 10 %), 500 rounds of an 8-leaf tree from sequential code 1.8 / 2.6 / 3.3 / 1.9
  vs 1.6 / 2.4 / 3.1 / 1.6, wrapped region 6.1 vs 6.0, ANode split 6.1 vs 6.3, leaf-array tree 6.2 vs 6.2 at 8 threads. The same holds with clang 19. **It does not remove the 0.15 ms round of a
  region reached from sequential code, nor the heap-continuation penalty.** Nothing to gain from `!` on this machine; not adopted (and adopting it would cost the `seq` fast path of the whole program).
* **clang 19 vs 14 on the same C**: array tail loops are ~20 % *slower* with 19 (balanced tree at 1 thread 821 vs 676 ms, split 620 vs 499), allocation-heavy list / tree code is up to 1.9x
  *faster* (`Vec.xor` shape 41 vs 80 ms; the phase-1 bookkeeping, row construction), the whole codec at one thread is 5-8 % faster at T = 1024 (K = 1000 setup 38 -> 35 ms, K = 4000 167 -> 156 ms,
  decode 162 -> 154) and up to 25 % at T = 16 (K = 1000: 11 -> 8 ms). `docs/benchmarks.md` has both tables; the tests and the default recipe stay on clang 14 (no `!` needs 19).
* Which parts of the codec can sit under ONE region: everything on the symbol side already does after this work (`Solver.apply_par`, `Codec.symbols_par`, `Codec.symbols_flat`, sliced decode,
  `Codec.encoder_flat`: each is a single fork tree). The plan (phase 1, phase 2) is a sequential chain and cannot.

## E2. The symbol side of one block as one parallel region

What was wrong with the earlier slicing (docs/perf.md section 4, docs/benchmarks.md: "slicing 1.0-1.5x SLOWER on 12 threads"), found with the lab:
(1) every slice task walked the SAME `Plan` lists (shared `Data`, G above) and each op was a list-node match; (2) a slice's table (65536 `G.mul` = 1.3 ms) and arena were built per task; (3) the read-out and
`vjoin` were fine. The fixes:

* `Solver.prog(plan)`: the plan compiled once (2 ms at K = 1000, 9 ms at K = 4000) into an `Array<U32>` of 3-word instructions; `apply` / `apply_arena` interpret it. Single thread, K = 1000, T = 1024:
  `Solver.apply` incl. read-out 45 -> 37 ms (no list walk per apply).
* `Solver.apply_par(d, ..)`: ONE fork tree of 2^d tasks; each clones the program, builds its own arena from its word slice of every rhs symbol (the subtrees of the balanced `Vec`s at depth d, no copy),
  replays, reads out; slices joined per symbol. `Flat.table` built by doubling (0.3 ms).
* `Codec.symbols_par`, sliced `Codec.decode_with_plan_auto` / `decode_auto` (apply AND the K source re-encodings inside each slice task), `Codec.encoder_flat` (slice arenas kept, `Solver.apply_ars`).
* `Solver.auto_depth` slices from 2^18 words of symbol data (was 2^23); measured break-even at 8 threads: K = 1000 T = 256 (68K words) loses, K = 1000 T = 1024 (274K words) wins 1.2x (setup), T = 4096 2.3x.

Measured (K = 1000 / 4000, T = 1024; `tools/scaling/apply_par.bend`, apply = program compile + replay + read-out as `Vec` trees, 1/2/4/8/12 threads with d = 0/1/2/3/3, min of 5):

| K | sequential apply | 2 thr | 4 thr | 8 thr | 12 thr | speedup at 8 |
|---|---|---|---|---|---|---|
| 1000 | 32 ms | 21 | 16 | 11 | 12 | 2.9x |
| 4000 | 139 ms | 76 | 55 | 39 | 38 | 3.6x |

(Before: `apply_par` d = 3 on 8 threads 42-50 ms at K = 1000, i.e. 0.9-1.1x of the sequential apply; 12 threads 81-101 ms; box loaded.) At 12 threads d = 2 is slower than d = 3 (16 / 55 ms): more slices help, the A520 tasks
gate the join. It is not 6.6x because: the program compile (2 / 9 ms) and the clone are sequential, a task's slice (32 words at T = 1024, d = 3) pays the same per-instruction overhead (~30 ns x 34K / 137K
instructions) as a full-width one, and 8 big cores of 2.2-2.6 GHz are not 8 equal cores.

**(c) per-pivot parallel Gauss-Jordan: dead end.** The dense tail (n = 79 .. 142 columns, rows of (n + m) / 4 words) costs ~35 us per pivot (about 140 row operations of ~70 words); a fork reached from sequential code
costs 150-300 us (rule 3). Per-pivot rounds would be 4-8x slower than the sequential loop; the tail solution is already inside the sliced apply program. Not implemented.

## E3. Single-thread overhead

| change | before -> after (1 thread, cpu0) |
|---|---|
| `Solver.prog` interpreter instead of list replay | apply (K = 1000, T = 1024) incl. read-out 45 -> 37 ms |
| phase 1 + row bookkeeping on flat arrays (`Solver.plan`, docs/solver.md; the list version is kept as `plan_ref`) | plan K = 1000 / 4000 / 10000 (rows built inside the clock): 26 / 152 / 467 -> 17 / 98 / 332 ms |
| dense (HDPC) rows enter phase 2 as term lists (no `tsort`, no `Vec` fold: 55 of 140 ms at K = 4000) | -> 10 / 57 / 179 ms |
| phase 2 column order from the column states (no sort + complement) | -> 10-12 / 49 / 151 ms |
| linear flat encoder (`Codec.encoder_flat`, `symbols_flat`): no tree -> flat copy-in, no read-out | repair of 1000 symbols (K = 1000, T = 1024) 14-16 -> 2-3 ms (Rust 1.2-1.8), setup 61 -> 38 ms |

Where one block's time goes now (K = 1000 / 4000, T = 1024, 1 thread, ms): rows 3 / 11, plan 10 / 49 (ingest 2 / 3, index + loop 1 / 2, post lists 3 / 7, phase 2 4 / 24), program compile 2 / 9, apply 25 / 118 (about
half of it multiply-adds: the 10 dense rows over all pivots and the dense tail solution; the instruction mix of the K = 1000 program is 14.7K xors, 15.9K multiply-adds, 2.1K copies), read-out (tree API only) ~5 / 20.
The apply is the SIMD-less floor: XOR 1.1 ns/word, table multiply 3 ns/word (docs/profile.md).

## Results: one block against the thread count

`docs/benchmarks.md` has the full tables against the Rust crate. ONE block (K = 1000 / 4000, T = 1024, 8 big cores for 2-8 threads, min of 3-5, quiet box):

| | thr | 1 | 2 | 4 | 8 | 12 |
|---|---|---|---|---|---|---|
| K = 1000 setup, flat API | ms | 38 | 30 | 25 | 21 | 21 |
| K = 1000 setup, tree API | ms | 41 | 34 | 25 | 20 | 21 |
| K = 1000 decode | ms | 34 | 27 | 25 | 20 | 20 |
| K = 1000 repair (1000 symbols), tree API / flat API | ms | 14 / 3 | 10 / 2 | 6 / 3 | 5 / 2 | 4 / 3 |
| K = 4000 setup, flat API | ms | 170 | 131 | 103 | 80 | 87 |
| K = 4000 setup, tree API | ms | 185 | 127 | 109 | 88 | 94 |
| K = 4000 decode | ms | 163 | 117 | 124 | 115 | 114 |
| K = 4000 repair (1000 symbols), tree API / flat API | ms | 48 / 3 | 27 / 3 | 20 / 4 | 11 / 3 | 13 / 3 |

Before this work all of these were flat in the thread count (K = 1000: setup 61 ms at 1 thread and 62 at 8; decode 55 / 54; repair 14 / 14; K = 4000: setup 302 / 300, decode 299 / 296, repair 47 / 49).

## Dead ends recorded

* Per-pivot parallel dense Gauss-Jordan (above): a round costs 4-8x a pivot.
* `Array.fork` as the way to share the program: correct and fastest, but `@unsafe` makes `scripts/check_proofs.sh` fail; `Array.clone` costs 0.1-0.5 ms per task and is accepted.
* `!` regions: identical to plain forks, and a single `!` in the program removes the `--threads 1` fast path of the whole binary.
* The table built by doubling saved ~1 ms per table but did not show in single-thread K = 1000 totals (inside noise); kept because every slice builds its own.
* clang 19: faster for the codec (list-heavy phases), slower for array loops; not adopted by default.
* Fused multi-source XOR (d = s1 ^ s2 ^ s3 in one pass) was considered; not done: the xor passes are 14.7K of 34K instructions (~4 ms of 25), the rest is multiply-add (table lookups).
* Parallelising the plan (phase 2 dense corrections per dense row, the program compile in segments) was estimated at 5-6 % of the K = 4000 total and not done.

## Verdict

*Does pure Bend scale across cores?* **Yes, on one shape, and this machine shows it cleanly when it is idle: 6.5-7x at 8 threads (of at most ~8) for a balanced fork tree whose leaves own their arrays, from 1 us leaves
up.** It does not scale for anything else: a fork reached from sequential code costs a 0.15-0.3 ms runtime round (a per-iteration fork is 0.03-0.4x), a def that contains a fork penalises its own sequential branch by 2x, a
`Data` structure shared by the tasks (a `Plan`, a list) is read through atomic refcounts (3.5x instead of 6.6x), the `Array.fork` that would share an array is `@unsafe` and rejected by the proof gate, and the 4 little
cores gate every static tree whose tasks do not outnumber the threads.

*Does ONE RaptorQ block scale?* **Partly: 1.5-2.1x end to end at 8 threads, 3-3.6x on its symbol side.** Single block K = 1000, T = 1024: setup 38 -> 21 ms, decode 34 -> 20 ms; K = 4000: setup 170 -> 80, decode 163 -> 115 ms
(2.1x / 1.4x); repair generation (flat API) is 2-3 ms at any thread count (the XOR work is 2.5 ms); apply alone 2.9x / 3.6x. It cannot scale further because the rest of the block is a sequential chain:
row construction (3 / 11 ms; `src/constraints.bend`, not touched here), phase 1 + phase 2 of the plan (10 / 49 ms, a greedy pivot chain whose per-step work is microseconds, 10x below the cost of a
parallel region), the program compile (2 / 9 ms), and for T = 16 the symbol work is only a few ms, so the whole block is that chain (K = 1000, T = 16: 1 thread 11 ms, 8 threads 11-12). The decoder has the same chain plus
a plan for its own matrix (K = 4000: 40 ms). What Bend would need to do better: a region round of ~10 us instead of 150-300 us (or work stealing inside a region) so that the per-pivot Gauss-Jordan and the dense-row
corrections could fork; no heap-continuation penalty for defs that contain a fork; `Array.fork` (shared read-only arrays) accepted by the proof gate or an equivalent safe primitive; a way to bias tasks to big cores
(or work stealing). What does scale is parallelism ACROSS blocks (docs/multiblock.md: one task per block, one plan shared per K) because every task is a leaf that owns its arrays.

*Single thread:* the Bend/Rust ratio of the cold setup went from 12.6x (K = 1000, T = 1024) / 15.2x (K = 4000) to 7.0x / 7.5x (flat API, one thread each, same core) and for T = 16 from 12.5x / 17x to 2.9x / 4.1x; at 8 threads it is
3.6x / 3.7x for T = 1024 and 4.2x / 5.2x for T = 16 (Rust is single-threaded; Bend's T = 16 time is the sequential plan). Repair generation with the flat API is 1.1-1.7x of Rust (was 20-60x). What is left at T = 1024
is the SIMD gap in the multiply-add (docs/benchmarks.md), at T = 16 the plan.
