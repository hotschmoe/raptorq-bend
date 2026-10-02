# Multi-block objects (RFC 6330 sections 3.3, 4.3, 4.4) -- `src/blocks.bend`, `src/blocks_demo.bend`

A source object of F octets is cut into Z source blocks (RFC 4.4.1.2), every block into N sub-blocks, and every source block is encoded and
decoded independently with the single-block codec of `src/raptorq.bend` (`docs/codec.md`). Blocks are independent, so this is the first place
where the repo has a genuinely parallel workload; most of this document is about how that is arranged for Bend's runtime and what it measured.

`import ./src/blocks.bend as B`, calls look like `B.Blocks.params(..)`. Pure Bend, no foreign code.

## What it implements

| RFC | `Blocks.*` |
|---|---|
| 4.4.1.2 `Partition[I,J] = (IL, IS, JL, JS)` | `partition(i, j) -> Part{il, ish, jl, js}` |
| 4.4.1.2 `(KL, KS, ZL, ZS) = Partition[Kt, Z]`, Kt = ceil(F/T) | `layout(oti) -> Lay{kt, kl, ks, zl, zs}`, `block_k(lay, sbn)`, `num_blocks(lay)` |
| 4.3 `K_L(n)` = largest Table 2 K' <= WS / (Al * ceil(T / (Al * n))) | `kl(ws, al, t, n)` (reads Table 2 through `R.params`, scanning down from the bound; K'max = 56403) |
| 4.3 derivation of T, Z, N from F, P', Al, WS, SS | `params(f, p, al, ws, ss) -> Maybe<Oti>` |
| 3.3.2 / 3.3.3 OTI (F, T, Z, N, Al), 12 octets | `Oti{f, t, z, n, al}`, `oti(f, t, z, n, al)` (validated), `valid`, `oti_bytes(oti)`, `oti_parse(bytes)` |
| 3.2 payload id (SBN 8 bit, ESI 24 bit) | `payload_id(sbn, esi) -> U32`, packets are `Pkt{sbn, esi, sym}` |
| 4.4.1.2 object -> blocks -> sub-blocks -> symbols | `split_object(oti, bytes) -> List<List<Sym>>` (K source symbols per block, last symbol zero padded, sub-block interleave for N > 1), `join_object` is its inverse |
| 4.4.2 encoding packets | `encode_object(w, oti, bytes)`, `encode_syms(w, oti, src)` -> `Maybe<Obj>`; `symbol(obj, sbn, esi) -> Maybe<Sym>`; `repair(w, obj, n)`; `encode_repair(w, oti, n, src)` (fused, see below) |
| 4.4.3 / 5.4 recovery | `decode_object(w, oti, pkts) -> Maybe<bytes>`, `decode_syms(w, oti, pkts) -> Maybe<List<List<Sym>>>` |

`w` is the number of leaf tasks of the block tree (1 = sequential; `w = Z` makes every block its own task, which balanced best, see below; anything >= `IO.thread_count()` works). `Obj{oti, lay, encs}` holds one `Codec.Enc` per block
(the intermediate symbols), so `symbol` is random access. `Pkt` replaces the `(sbn, esi, Sym)` triple. Packets of unknown blocks are ignored, duplicates
and arbitrary order are fine, a block with fewer than K symbols (or a rank-deficient set) makes the object `None`.

Limits: F is a `U32` (the RFC allows 40 bit: objects up to 4 GiB - 1), Z <= 255 (OTI field is 8 bit), T <= 65535, Al <= 255, N <= T/Al, K <= 56403 per block
(`ceil(Kt/Z) <= 56403`, checked by `valid`). The 12 octets of a 40-bit F whose top octet is non-zero are rejected by `oti_parse`.
Sub-blocks (N > 1) are implemented as the RFC describes: they only permute the octets of the source block (symbol m = concatenation of the m-th
sub-symbol of every sub-block); the code itself is applied to whole T-octet symbols, exactly as the Rust crate does it.

## Parallel design

Rules this design follows (`docs/profile.md` sections 6-7, `docs/scaling.md` rules 1-6):

1. **One parallel region per phase, outermost, fork tree.** Forks reached from sequential code cost ~0.3 ms and forks inside a running task are free, so
   every parallel function (`encode_*`, `repair`, `decode_*`) is ONE divide and conquer over the block range `[0, Z)` for `w` workers: a node with `w`
   leaf tasks and `n` blocks gives its left child `floor(w/2)` workers and `n*floor(w/2)/w` blocks (proportional split, so `w = 12, n = 64` gives leaves of
   5 and 6 blocks, not 4 + 4 + ... + 16 tasks on 12 threads), forks `a b = range(left) range(right)` and appends the result lists. `levels(w)` is the
   recursion fuel. The only other fork reached from sequential code is the pair of plan computations that precede the tree (below).
2. **Leaves are tail-recursive loops.** A leaf (one worker, or a single block) runs its blocks one after the other in `leaf(..)`, a tail loop whose body is
   `blk(cx, sbn, inputs)`. The fork-free recursion sits in its own def, never in the def that contains the fork (`docs/scaling.md` rule 4: a def that merely
   contains a parallel `let` makes all its non-tail calls heap-allocate continuations at `--threads > 1`). The per-block code (`Solver.apply`, `Flat.*`) is
   tail loops over arrays: measured, one leaf runs at the same speed at `--threads 1`, 2 and 8 (257 / 254 / 255 ms for 8 blocks).
3. **No sharing of `Data` between leaves where it can be avoided.** The source symbols are dropped down the tree (`List.drop` of the left part), the received
   packets are *routed* down the tree: every node partitions its packet list by `sbn < mid` (order-preserving), so a leaf only ever sees its own blocks'
   packets and no list is scanned once per block (a 64-block, 64000-packet decode partitions in 6 passes, the first sequential and the rest inside tasks).
4. **Plans are shared, per K and (decoder) per ESI sequence.** The plan (symbol-independent half of the solve, `Codec.plan_for`) depends only on K and which
   ESIs arrive in which order. All ZL blocks have K_L, all ZS blocks K_S, so the encoder computes at most two plans (`Codec.encoder_plan`, concurrently),
   once, before the tree. The decoder takes the packets of the first block of each class, computes `plan_for(K, esis)` for those two (concurrently), and every
   block whose ESI sequence is *identical* to its class representative's reuses that plan; a block with a different loss pattern builds its own inside its
   leaf. `tests/blocks_test.bend` checks both (the "same losses in every block" and "different per block" scenarios).
5. **Fused encode + repair on the flat arena** (`encode_repair`): `Codec.encode_with_plan` returns an `Enc` (trees of boxed words for the L intermediate
   symbols) and `Codec.symbols` copies them back into a flat array. `Blocks.encode_repair` instead uses the linear flat encoder of `docs/codec.md`
   (`Codec.encode_with_plan_flat(0, ..)` keeps the solved arena, `Codec.symbols_flat` generates the repair symbols from it, `Codec.out_vecs` reads them out) inside the leaf: no tree
   conversion of the intermediate symbols and no `Enc`/`Obj`. `encode_syms` + `repair` (the `Obj` path, random access to any symbol later) is 1.8x more work for the same
   repair symbols (1038 ms vs 585 ms for 16 blocks of K = 1000, T = 1024, one thread, measured with the previous internal version of the same idea; the linear API gives 534 ms).

The decoder returns the K source symbols re-encoded from the intermediate symbols (like `Codec.decode_with_plan`); received source symbols are not copied through.

## Tests

* `tools/vectors3/` (cargo project on the vendored crate, `cd tools/vectors3 && cargo run --release`) writes `tests/vectors3/*.txt` (formats and regeneration
  in `tests/vectors3/README.md`): `partition` (118 `(I,J)` cases), `kmax` (40), `params` (720 `generate_encoding_parameters` cases: 532 derived (T, Z, N), 188 where
  the true Z exceeds 255 and the crate silently truncates it to u8, which Bend must reject), 11 objects with the OTI bytes the crate serializes, every source and
  repair packet of every block (1681 packets) and 33 decode scenarios with losses spread over the blocks (the crate's own `Decoder` recovers each one).
* `python3 tools/gen_blocks_test.py` turns them into `tests/blocks_fixtures.bend`; `bend tests/blocks_test.bend` (about 10-20 s): partition vectors and the
  arithmetic laws on a 70 x 70 grid, `kmax`, all 720 parameter cases, OTI layout / serialization / parsing / rejections, then for each of the 11 objects (Z = 1 .. 11,
  ZL and ZS blocks, K = 5 .. 63 so K' padding happens, T = 4 .. 32 incl. odd T = 5, Al = 1 .. 8, N = 1 .. 5): `split_object` equals the crate's source packets, every
  source and repair packet equals `Blocks.symbol` of `encode_object`, `Blocks.repair` and the fused `encode_repair` equal the crate's repair packets, and `decode_object`
  recovers the object from every scenario (and returns `None` when a whole block is missing), each for 1, 3 and 5 workers (the tree shapes differ, the results do not).
  Prints one line per group and `ALL PASS`.
* `scripts/test_all.sh` picks the suite up (it globs `tests/*_test.bend`).

## Results: how Bend scales on this workload

**Workload.** One object of Z = 64 source blocks of K = 1000 symbols of T = 1024 octets (65.5 MB; Kt = 64000, ZL = 0, one K class, so one plan), N = 1.
*Encode* = `Blocks.encode_repair`: the plan (`Codec.encoder_plan`, sequential, ~14 ms) once, then per block the solve on the arena and 879 repair symbols
(K - ceil(K/8) + 4), read out as `Vec` symbols. *Decode* = `Blocks.decode_syms` from exactly K symbols per block, 7/8 of them repair (the hard case of
`docs/benchmarks.md`), the same ESIs in every block (shared plan: the representative's plan takes ~12 ms). The decoded blocks are compared with the source
(`ok=1`, outside the timed phases). Source generation and packet building are not included.

**Machine and honesty.** 12 cores that are not equal (`docs/scaling.md`): 8 Cortex-A720 (2.2-2.6 GHz) and 4 Cortex-A520 at 1.8 GHz that are ~3.5x slower. The
box was shared: another user's builds kept the load average at 13-20 earlier in the day and at 3-6 during these runs, so every multi-thread number is a lower bound
and runs differ by 10-30% (an earlier, busier sweep gave 4.8x / 6.7x at 8 threads for plain forks; the table below is the later one). Bend 2.0.34, native binaries, IO
`main`, wall clock of each phase, **min of 5 runs**, `tools/blocks_sweep.sh` (raw lines in `build/blocks_sweep.txt`). Rows with <= 8 threads are pinned to the 8 big
cores (`taskset`), 1 thread to one A720 (2.5 GHz), 12 threads is unpinned. Speedup = 1 thread / t threads; "eff" = speedup / t. The 1-thread time is the same code at
`--threads 1` (the runtime's `seq` fast path), not a different algorithm.

| threads | encode+repair, w = t leaves | speedup | eff | w = 64 leaves | speedup | eff | `!` call, w = t | speedup |
|---|---|---|---|---|---|---|---|---|
| 1 | 1933 ms | 1.00x | 100% | | | | | |
| 2 | 955 | 2.02x | 101% | 946 | 2.04x | 102% | 958 | 2.02x |
| 4 | 522 | 3.70x | 93% | 517 | 3.74x | 93% | 522 | 3.70x |
| 8 | 301 | 6.42x | 80% | 300 | 6.44x | 81% | 309 | 6.26x |
| 12 | 377 | 5.13x | 43% | **275** | **7.03x** | 59% | 376 | 5.14x |

| threads | decode, w = t leaves | speedup | eff | w = 64 leaves | speedup | eff | `!` call, w = t | speedup |
|---|---|---|---|---|---|---|---|---|
| 1 | 2834 ms | 1.00x | 100% | | | | | |
| 2 | 1311 | 2.16x | 108% | 1169 | 2.42x | 121% | 1320 | 2.15x |
| 4 | 682 | 4.16x | 104% | 654 | 4.33x | 108% | 693 | 4.09x |
| 8 | 396 | 7.16x | 89% | 398 | 7.12x | 89% | 416 | 6.81x |
| 12 | 494 | 5.74x | 48% | **369** | **7.68x** | 64% | 481 | 5.89x |

Efficiencies above 100% are real: the 1-thread run touches the whole 1 GB working set from one core (per-block cost 30 ms / 44 ms at 64 blocks against 30 / 38 ms for
a 16-block object: cache, TLB and allocator growth) and the other cores clock up to 2.6 GHz against 2.5 for the baseline core. The capacity-weighted ideal of this
machine is ~7.7x for the 8 big cores and ~8.8x with the 4 little ones (~0.28 of a big core each), not 8 and 12.

**The ceiling: no Bend scheduler at all.** `procs` = t independent single-thread *processes*, one per big core, each doing 64/t blocks (each computes its own
plan), time = the slowest one: encode 982 / 516 / 305 ms (1.97 / 3.75 / **6.34x**) and decode 1330 / 646 / 364 ms (2.13 / 4.39 / **7.79x**) at 2 / 4 / 8. That is what
this box allows this workload when nothing is shared. The block tree reaches 6.44x of 6.34x (100%) for encode and 7.12x of 7.79x (91%) for decode at 8 threads.
The gap between 6.3-7.8x and the capacity ideal of 7.7x is the machine, not Bend: eight processes that each need 252 ms alone for their 8 blocks need 305 ms when they run together
(shared L3 / DRAM bandwidth, frequency, the other jobs on the box).

**Per-block cost against the single-block numbers** (one thread pinned to an A720, K = 1000, T = 1024, min of 6): Z = 1 takes 44 ms to encode (plan ~14 + block ~30, incl. the 879
repair symbols) and 50 ms to decode (plan ~12 + block ~38); every further block costs 30-33 ms (encode) and 38-40 ms (decode) for Z = 2 .. 16 (per block 31 / 39 ms at Z = 16)
and 30 / 44 ms at Z = 64 (cache / allocator effects). The single-block decode of `docs/benchmarks.md` was 93 ms before the flat-program apply and the Rust crate needs 5.9 ms.
So sharing the plan saves ~14 of 44 ms (encode) and ~12 of 50 ms (decode) per additional block: 64 blocks cost 1933 ms instead of 64 x 44 = 2816 ms (1.46x) to encode and
2834 ms instead of 64 x 50 = 3200 ms (1.13x) to decode. With a different ESI pattern per block (`bench ... pat=1`, Z = 16) every pattern builds its own plan inside its leaf: decode
562 -> 737 ms on one thread (+31%), 112 -> 133 ms at 8 threads (+19%); the encoder is unaffected (535 vs 532 ms: its plan depends on K only).
For scale: the Rust crate (single threaded, no multi-block parallelism) needs 64 x 5.9 = 378 ms to decode this object and 64 x 4.4 = 282 ms to encode + generate 1000
repair symbols per block with a cached plan; Bend at 8 threads takes 398 and 300 ms, i.e. about one Rust core.

**Size of the object, 8 threads on the big cores, w = Z, 1 thread -> 8 threads** (min of 6):

| Z (blocks) | encode+repair | decode |
|---|---|---|
| 8 | 252 -> 54 ms (4.67x) | 304 -> 65 ms (4.68x) |
| 16 | 487 -> 108 (4.51x) | 615 -> 130 (4.73x) |
| 32 | 970 -> 199 (4.87x) | 1280 -> 253 (5.06x) |
| 64 | 1933 -> 300 (6.44x) | 2834 -> 398 (7.12x) |
| 128 | 3867 -> 580 (6.67x) | 6835 -> 783 (8.73x) |

Small objects are dominated by fixed costs of ~50 ms that do not shrink with threads (the sequential plan, ~14 ms, plus waking the pool and the first region), so 8 blocks on 8 threads
reach 4.7x; from 64 blocks on the fixed part is below 20% of the 8-thread time. The 8.7x at Z = 128 is helped by the 1-thread baseline's cache effects (53 ms per block there).

### Interpretation: what Bend does and does not give here

* **It scales, on exactly the shape the runtime handles.** Blocks are a coarse-grained fork-join workload (30-45 ms leaves, no sharing between leaves except the read-only plan) and
  that is what `docs/scaling.md` rules 1 and 3 say the runtime handles well: one top-level region per phase, balanced tree, tail-loop leaves, results appended on the way back up.
  8 big cores give 6.4x (encode) / 7.1x (decode) over one core, 100% / 91% of what 8 independent processes get on the same box, and 12 cores 7.0x / 7.7x (with over-decomposition, below).
  Nothing in the per-block code needed to know about threads: one leaf runs at the same speed at `--threads` 1, 2 and 8 (257 / 254 / 255 ms for 8 blocks, `w = 1`), because the
  per-block work is array tail loops (`Solver.apply`'s flat program, `Flat.generate`), not recursive tree code.
* **Over-decompose when the cores are unequal or busy.** The runtime deals each task to a thread once and never moves it (no work stealing): a tree with exactly as many leaves as
  threads is gated by its slowest leaf. With 12 threads (8 A720 + 4 A520 that are 3.5x slower) a 12-leaf tree gives 5.1x / 5.7x, *worse* than 8 pinned threads (6.4x / 7.2x), because the
  join waits for the leaves that landed on little cores; 64 leaves (one per block) give 7.0x / 7.7x, i.e. the extra cores are worth ~10% over 8 big cores. At 8 big cores the two
  agreed in this sweep (300 vs 301 ms; in the earlier, busier sweep 334 vs 414 ms encode). The register-loop calibration of the same tree shows the effect in pure form
  (`blocks_lab calib`: 2569 ms at 1 thread; 1288 at 2 and 1285 at 4 threads with w = t leaves, 689 at 8; but 765 ms at 4 threads when w = 64): with only t leaves two of them can
  land on one thread. Over-decomposing 8x costs nothing measurable (a task is tens of nanoseconds, `docs/scaling.md`), so `w = Z` is the recommended setting (the demo's default).
* **What limits it** (largest first): (1) the machine: 12 cores are ~8.8 big-core equivalents, eight concurrent processes slow each other by ~20% (memory), other jobs on the
  box; (2) Amdahl: the plan (~14 ms encode, ~12 ms decode) is sequential before the tree: 5% of the 8-thread encode and the reason an 8-block object reaches only 4.7x;
  (3) static task placement without stealing (w = t vs w = 64 at 12 threads); (4) the 4 little cores. Not limiting: fork overhead (1 region + ~64 tasks), plan sharing
  (below), the non-tail penalty of `docs/profile.md` section 6 (leaf code is tail loops; measured above), allocation (per-lane free lists: RSS is 1.1 GB for 1 or 8
  threads and 0.83 GB with one leaf per block at 8 threads).
* **Sharing the plan is free, now.** I expected the shared `Plan` (a `Data` list structure read by every task) to be the scaling trap of `docs/scaling.md` section G
  (atomic refcounts on shared nodes). With the flat-program `Solver.apply` (each application compiles the plan to a private array program, ~2 ms at K = 1000) it is not: 64 sub-objects
  or 8 sub-objects that each compute their own plan (`blocks_lab priv`) are *slower*: at t = 8, 788 ms for encode + decode against 697 ms with the shared plan (+13%); t = 4: 1389 vs 1204;
  t = 12: 1129 vs 871. The plan costs ~14 ms to build and ~2 ms per block to compile, shared or not.
* **`!` buys nothing on the CPU.** `Blocks.encode_repair!(..)` / `decode_syms!(..)` (clang 19 build of `tools/blocks_lab.bend`, `--gpu off`) give the same curves within noise or slightly worse
  (6.26x vs 6.42x encode at 8 threads, 6.81x vs 7.16x decode; the same calibration curve). The block tree already is the "outermost parallel call" `!` is meant to hand over; on
  this machine it uses the same fork-join pool.
* **Against C.** One Rust core does this object's decode in 378 ms; Bend needs 8 big cores for 398 ms. The per-core gap of `docs/benchmarks.md` (7-25x) is not closed by
  multi-block parallelism, it is hidden by it: Bend on all 12 cores (~8.8 big-core equivalents) is worth about one Rust core on this workload; a Rust build that parallelised over blocks
  would scale the same way and stay ~8x ahead.

### Reproducing
```
export PATH="$HOME/.bend/bin:<dir with clang -> /usr/bin/clang-19>:/usr/bin:/bin" BEND_NO_TELEMETRY=1      # clang 19 only for the `!` call sites of blocks_lab
tools/blocks_sweep.sh 64 1000 1024 5                      # the tables above (about 10 minutes; build/blocks_sweep.txt has the raw lines)
bend src/blocks_demo.bend -o build/blocks_demo            # clang 14 is fine for the library and this demo
./build/blocks_demo --threads 8 -- bench 64 1000 1024 0 64 1     # bench Z K T [pat [W [fused]]]: gen / enc / rep / dec / verify, one BLOCKS line
bend tools/blocks_lab.bend -o build/blocks_lab && ./build/blocks_lab --threads 8 --gpu off -- bench 64 1000 1024 64 1     # `!` variant (last arg 1)
```
Notes for builders: with clang 14 the whole program is one huge function (`work_loop` with every def inlined); while writing this a program that reached `raptorq` + `blocks` + a main with
several dozen defs (about 2.85 MB of C) hit a clang 14 backend crash ("Cannot scavenge register without an emergency spill slot"), and compiled again after the demo's
`Cx`/stage code was slimmed. `src/blocks_demo.bend` (3.0 MB of C) builds with clang 14 today; its calibration / `!` / private-plan experiments live in `tools/blocks_lab.bend`, which needs
clang 19 anyway. Growing `raptorq`/`solver`/`flat` further can bring the cliff back.

## Requests (for the owners of `src/raptorq.bend`, `src/solver.bend`)
1. (done, adopted) the fused path now uses the public linear flat encoder (`encode_with_plan_flat` / `symbols_flat` / `out_vecs`); it was the same speed as my first version that called
   the internals `wp.rhs` / `wp.ok` directly.
2. **Compile the plan once per leaf, not once per `Solver.apply`**: `apply` compiles the `Plan` into the flat program every call (~2 ms at K = 1000, 6% of a 30 ms block; ~130 ms of CPU for 64
   blocks sharing one plan). An `apply_many(plan, [rhs ..])` (or a compiled-program value that can be cloned per block with `Array.clone`) would remove it.
3. **A parallelisable / cheaper plan**: the ~14 ms sequential plan is the largest Amdahl term of both phases (5% of the 8-thread encode, 27% of an 8-block object's); nothing here can overlap it.
4. **clang 14 inlining**: see "Notes for builders" above; either `__attribute__((noinline))` on the big segments in the generated C or a size-aware `-O` would remove the cliff (not something repo code can fix).
5. F is a U32 here (RFC: 40 bit, objects up to 946270874880 octets); Bend has no wider integer, so larger objects need a (hi, lo) pair throughout `Oti`/`layout`.
