# Benchmarks: Bend codec vs the Rust `raptorq` crate

Honest comparison of this repo's pure-Bend implementation (no C/NEON effects, no non-Bend fallbacks) against cberner/raptorq 2.0.1
(the vendored copy in `tools/vectors/vendor/raptorq`, which is what the golden vectors come from; its aarch64 kernels are NEON,
`octets.rs`, default `std` feature). Both are bit-exact RFC 6330 for these inputs (decoded output is verified equal to the source in every
run, `ok=1`). The purpose is to test the Bend authors' "on par with C" claim on a real workload: where the answer is "yes", "no" and why is
in the last section.

## Setup
* Machine: aarch64, 12 cores (big.LITTLE-style cix SoC: Cortex-A720 up to 2.6 GHz + Cortex-A520 up to 1.8 GHz, i.e. the 12
  cores are NOT equal), 30 GB RAM, Linux 6.6. Debian clang 14.0.6 (`/usr/bin/clang`) builds the Bend binaries, Bend 2.0.34,
  rustc 1.96.0 `--release` (opt-level 3, LTO, no `target-cpu=native`).
* Workload (single source block, systematic code, one symbol = T octets, K source symbols of LCG data):
  1. **setup** = computing the intermediate symbols from the K source symbols (RFC 5.3.3.4; the matrix solve), plus forcing the first
     repair symbol (Bend is lazy; the Rust figure is `SourceBlockEncoder::new`);
  2. **repair** = generating N = 1000 repair symbols from the intermediate symbols. Bend's figure includes the harness walking every
     word of every result (a checksum, 13 ms at K = 1000, T = 1024; 45 ms at K = 10000), Rust's includes copying each symbol out;
  3. **decode** = recovering the K source symbols from exactly K received symbols, 7 of 8 of them repair symbols (the hard case);
     Bend re-encodes all K source symbols from the solution, the Rust decoder (probably) only the missing ones.
* Bend: `tools/bench/bench.bend` (`Codec.encoder_auto` / `Codec.decode_auto` / `Codec.symbols`), native binary, IO `main`, wall clock via
  `IO.now`, `--threads 1` and `--threads 12`. Rust: `tools/bench_rs` (single-threaded; the crate has no parallel solver), `Instant`.
  Minimum of 3 runs, each run a fresh process; the single-thread Bend runs and all Rust runs are pinned to one Cortex-A720 core
  (`taskset -c 11`), the 12-thread runs are not. Row construction of the Bend matrix is included in setup/decode (4 ms at K = 1000).
  Other jobs share the machine: +-10-30 % noise between runs, so ratios are good to about that.
* Reproduce: `PIN=11 tools/bench/run.sh 3` (writes `build/bench_results.txt`, 12 minutes), tables with `tools/bench/table.py`.

## Results (milliseconds, min of 3; "Bend/Rust" = slowdown factor of Bend)

### Encoder setup, Rust cold (fresh process: plan generation = the solve)

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.3 | 2.0 | 6.7x | 6.0 | 20.0x |
| 100 | 1024 | 0.6 | 6.0 | 10.0x | 12 | 20.0x |
| 1000 | 16 | 2.4 | 30 | 12.5x | 34 | 14.2x |
| 1000 | 1024 | 5.4 | 68 | 12.6x | 72 | 13.3x |
| 4000 | 16 | 9.9 | 168 | 17.0x | 168 | 17.0x |
| 4000 | 1024 | 23 | 354 | 15.2x | 354 | 15.2x |
| 10000 | 16 | 30 | 557 | 18.9x | 536 | 18.2x |
| 10000 | 1024 | 69 | 1069 | 15.5x | 1049 | 15.2x |

### Encoder setup, Rust warm (plan cached, only replayed)

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.0 | 2.0 | >40x | 6.0 | >120x |
| 100 | 1024 | 0.3 | 6.0 | 20.0x | 12 | 40.0x |
| 1000 | 16 | 0.1 | 30 | 300.0x | 34 | 340.0x |
| 1000 | 1024 | 3.1 | 68 | 21.9x | 72 | 23.2x |
| 4000 | 16 | 0.5 | 168 | 336.0x | 168 | 336.0x |
| 4000 | 1024 | 14 | 354 | 25.3x | 354 | 25.3x |
| 10000 | 16 | 1.2 | 557 | 464.2x | 536 | 446.7x |
| 10000 | 1024 | 40 | 1069 | 26.4x | 1049 | 25.9x |

### Generate 1000 repair symbols

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.2 | 1.0 | 5.0x | 0.0 | 0.0x |
| 100 | 1024 | 0.9 | 18 | 20.0x | 20 | 22.2x |
| 1000 | 16 | 0.4 | 1.0 | 2.5x | 0.0 | 0.0x |
| 1000 | 1024 | 1.3 | 30 | 23.1x | 30 | 23.1x |
| 4000 | 16 | 0.7 | 1.0 | 1.4x | 1.0 | 1.4x |
| 4000 | 1024 | 2.1 | 71 | 33.8x | 72 | 34.3x |
| 10000 | 16 | 1.0 | 2.0 | 2.0x | 2.0 | 2.0x |
| 10000 | 1024 | 2.6 | 154 | 59.2x | 153 | 58.8x |

### Decode from K symbols (7/8 repair)

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.3 | 3.0 | 10.0x | 2.0 | 6.7x |
| 100 | 1024 | 0.6 | 8.0 | 13.3x | 8.0 | 13.3x |
| 1000 | 16 | 2.1 | 31 | 14.8x | 30 | 14.3x |
| 1000 | 1024 | 5.9 | 93 | 15.8x | 91 | 15.4x |
| 4000 | 16 | 10 | 211 | 20.1x | 205 | 19.5x |
| 4000 | 1024 | 27 | 499 | 18.6x | 491 | 18.3x |
| 10000 | 16 | 30 | 734 | 24.9x | 724 | 24.5x |
| 10000 | 1024 | 81 | 1541 | 19.1x | 1510 | 18.7x |

### Before and after the flat-symbol work (Bend, 1 thread, ms)

"Before" = the tree-symbol code of commit 2df14a4 (a symbol = a `G.Vec` tree, one `VNode` + one `VWord` heap node per 4 octets; the numbers of the
previous version of this page, same machine), "now" = this table. The ratios to Rust shrank from 13-55x to 7-19x for the solve and from
12-110x to 7-25x for decode (T = 1024: 55x -> 15x and 99-110x -> 19x).

| K | T | setup before -> now | repair before -> now | decode before -> now |
|---|---|---|---|---|
| 1000 | 16 | 56 -> 30 | 4 -> 1 | 55 -> 31 |
| 1000 | 1024 | 287 -> 68 | 87 -> 30 | 408 -> 93 |
| 4000 | 16 | 300 -> 168 | 5 -> 1 | 401 -> 211 |
| 4000 | 1024 | 1419 -> 354 | 111 -> 71 | 2335 -> 499 |
| 10000 | 16 | 941 -> 557 | 6 -> 2 | 1457 -> 734 |
| 10000 | 1024 | 4066 -> 1069 | 130 -> 154 | 6961 -> 1541 |

(10000 / 1024 repair got slower in the table because of the harness checksum walk on a cache-cold block; see the repair notes below. The
stages of this work are separate commits with their own numbers: Stage 1 flat repair + re-encode, Stage 2 arena apply, Stage 2b arena plan.)

## Reading the numbers
* **Bend is now 7-19x slower than Rust for the solve (setup, T = 16 and 1024; 12-19x for K >= 1000), 7-25x for decode, and for T = 1024 repair
  generation 20-60x**, instead of 13-55x / 12-110x / 52-92x (1 thread). No hiding the rest: the Rust crate is mature and SIMD-optimised (NEON nibble-table
  `vqtbl1q_u8` kernels for XOR and multiply-add, a cached encoding plan, `u8` data in contiguous memory); this one is pure Bend.
* **Where the time goes now** (K = 1000 / 4000, T = 1024, 1 thread, ms; `tools/profile/bench_apply.bend`, `bench_flat.bend`): phase 1 (normalisation, weights,
  pivoting; lists and `Array<Rw>`, T independent) 22 / 123, row construction plus the coefficient side of the plan on the flat arena (pivot
  vectors, dense-row correction, tail Gauss-Jordan) together 7 / 40-80, `Solver.apply` on the symbol arena
  33 / 150 (about 7.5M / 35M words of symbol arithmetic = 4.4 ns per word including cache misses), read-out of the solution as `Vec`
  trees 8 / 40. At T = 16 everything except the plan is below 10 %: the T = 16 solve is bookkeeping (phase 1) in Bend and in Rust
  (Rust cold solve 2.4 ms at K = 1000, 12-13x), the factor 12-19x is our phase 1 (many list passes, allocation) against Rust's tuned sparse
  structures, not symbol arithmetic.
* **The remaining symbol-arithmetic gap is SIMD.** On flat `Array<U32>` the Bend kernels run at C scalar-table parity (docs/profile.md
  section 4: multiply-add 2.9-3.4 ns/word against 2.8 for scalar C with the same table; XOR 1.1 ns/word, 3.5 ns per op at 4 words = C),
  but the Rust crate and the C NEON model do 16 octets per instruction: multiply-add 0.38 ns/word, XOR 0.16, i.e. 7-9x and 5-7x less. Bend 2.0.34
  has no SIMD/vector type, no `U8`/`U64`, and `Array` access costs a runtime operation per slot (1-2 ns, C: ~0.3). That is the whole
  difference on the symbol side; it is not a layout problem any more. The gap at T = 1024 splits roughly in half
  (K = 1000: Bend 68 ms = ~28 ms phase 1 and rows + ~5 ms coefficients + 33 ms symbol replay + ~8 ms read-out into `Vec`s; with infinitely fast
  symbol arithmetic Bend would still need ~30 ms against Rust's complete 5.4 ms, so the other half is the bookkeeping (phase 1: list passes and `Array<Rw>` records; a cons-list proxy of it runs within 2x of arena-allocated C,
  docs/profile.md section 2 #4, so this is our algorithm and data structures, mostly not a Bend deficit, and not SIMD).
* **Kernel-level check of "on par with C"** (`tools/profile/mb_arena.bend`, one array holding symbols and the 64K product table,
  10M words per measurement, ns per word): XOR 1.1; multiply-add by the 64K table 3.4; bit-sliced SWAR with hoisted `c * alpha^i` 4.7
  (loses by 1.4x); the Nat-fuel SWAR loop (`G.mulw`) 10. So the table is the best pure-Bend multiply in the arena setting and is what
  `Solver.apply` and the plan use (SWAR below 8 words per symbol, where building the table costs more than it saves).
* **Repair generation (T = 1024) is the weakest row and mostly not arithmetic.** For K = 1000, N = 1000: the XOR loops themselves take
  2.5 ms (1.8M words, 1.4 ns/word; Rust 1.3 ms for everything), but `Codec.symbols` is `Data -> Data`: `Enc` cannot hold an `Array` (linear), so
  every call copies the shared intermediate `Vec` trees into the flat array once (5.5 ms, reading shared trees: refcount traffic and cache
  misses) and reads every result symbol out into `Vec` trees (7.5 ms, two allocations per word); the harness then walks the results
  (13 ms). Hence 30 ms in the table against 2.5 ms of kernel. A linear API that keeps the arena and hands out flat words would remove the
  first two; not done (it would add a second public encoder type).
* **Threads:** `--threads 12` no longer changes the numbers (the two columns agree within noise) because `Solver.solve_auto` /
  `decode_auto` slice the symbols only for blocks of at least 2^23 words (32 MB; `Solver.auto_depth`): with the arena apply costing
  about 4 ns per word, 8 slices save less than they cost in fork rounds, per-slice tables and read-outs (measured on 12 threads: K = 1000..4000,
  T = 1024: slicing 1.0-1.5x SLOWER; K = 10000: +-0). Before this work slicing gave 2.0-2.7x at T = 1024 because the tree kernels were slow. The remaining
  parallelism opportunity is in the plan (phase 1 is a sequential chain) and, for many blocks, across blocks.
* **The 12-thread anomalies of the old table are explained** (docs/profile.md section 6): the generated C has a fast path for non-tail calls
  (`seq`) that is taken only when the process has exactly one worker thread; with `--threads` > 1 every non-tail call allocates a continuation
  task, so tree walks (`Vec.xor`, `Vec.muladd`, the old repair generation) ran 2.2x slower at 12 threads than at 1 (repair 87 -> 161 ms at K = 1000,
  T = 1024; decode at K = 100, T = 1024 went 35 -> 83 ms), independent of any fork. Tail-recursive array loops are not affected, so the
  flat code has no 12-thread penalty (the Vec read-out and harness walk that remain are tree walks, hence repair at 12 threads is equal or a
  few percent worse). A parallel Bend process also pays about 25-30 ms of thread-pool start-up once.
* Rust "warm" (plan cached) is what a long-running Rust process pays for the second and later blocks of the same K. Bend has the same
  mechanism (`Codec.encoder_plan` + `encode_with_plan`, docs/plan_apply.md), and a block with a ready plan costs 39 / 177 ms at K = 1000 / 4000
  (T = 1024), against Rust warm 3.1 / 14 ms (12-13x).

## Caveats
* Single machine, heterogeneous cores, one run configuration; timings vary +-10-30 % between runs (the table is min of 3). Not tuned: no
  `target-cpu=native` for Rust, default Bend flags.
* Rust numbers are for the vendored 2.0.1 sources with the `std` feature (plan cache on, NEON kernels); the vendored copy is unchanged except
  the intermediate-symbol accessor (tools/vectors/vendor/README.md).
* The workload (7/8 repair decode, LCG data) is one point; the decoder time depends on the received pattern.
* Bend's `Codec.decode` recomputes all K source symbols from the intermediate symbols (it does not copy the received source
  symbols), the Rust decoder (probably, not verified) keeps the received source symbols and only recomputes the missing ones.
* Peak memory (`tests/solver_bench.bend` mode 5, K' = 56403, solve + two row builds, 1 thread, `tools/profile/rss.py`): 282 MB at T = 16 and
  852 MB at T = 1024 (the tree solver: 288 / 942 MB; the symbol arenas are 4 octets per slot plus up to 2x padding to a power of two, but the
  lists of phase 1 and the rows dominate); the K' = 56403 solve takes 7.2 s / 12.6 s wall (was 15 / 36 s). Rust not measured. Bit-exactness at
  scale: `tests/solver_bench.bend` mode 5 prints the same checksum of C as the pre-change solver for K = 4000 (T = 16) and K = 10000 (T = 1024;
  solve 5613 -> 876 ms, loaded machine).
