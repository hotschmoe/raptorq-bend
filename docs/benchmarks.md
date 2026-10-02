# Benchmarks: Bend codec vs the Rust `raptorq` crate

Honest comparison of this repo's pure-Bend implementation (no C/NEON effects, no non-Bend fallbacks) against cberner/raptorq 2.0.1
(the vendored copy in `tools/vectors/vendor/raptorq`, which is what the golden vectors come from; its aarch64 kernels are NEON,
`octets.rs`, default `std` feature). Both are bit-exact RFC 6330 for these inputs (decoded output is verified equal to the source in every
run, `ok=1`). The purpose is to test the Bend authors' "on par with C" claim on a real workload: where the answer is "yes", "no" and why is
in the last section.

## Setup
* Machine: aarch64, 12 cores (big.LITTLE-style cix SoC: Cortex-A720 up to 2.6 GHz + Cortex-A520 up to 1.8 GHz, i.e. the 12
  cores are NOT equal; docs/scaling.md has the per-core capacities), 30 GB RAM, Linux 6.6. Debian clang 14.0.6 (`/usr/bin/clang`) builds the Bend binaries, Bend 2.0.34,
  rustc 1.96.0 `--release` (opt-level 3, LTO, no `target-cpu=native`).
* Workload (single source block, systematic code, one symbol = T octets, K source symbols of LCG data):
  1. **setup** = computing the intermediate symbols from the K source symbols (RFC 5.3.3.4; the matrix solve), plus forcing the first
     repair symbol (Bend is lazy; the Rust figure is `SourceBlockEncoder::new`);
  2. **repair** = generating N = 1000 repair symbols from the intermediate symbols: the Bend figure is the CALL only (`Codec.symbols_auto`; for the flat API `symbols_flat` plus an in-place checksum over the
     result arrays), the harness walk over every word of every result tree (12-13 ms at K = 1000, T = 1024) is reported separately (`repair_walk_ms`) and no longer in the figure; Rust's includes copying each symbol out;
  3. **decode** = recovering the K source symbols from exactly K received symbols, 7 of 8 of them repair symbols (the hard case);
     Bend re-encodes all K source symbols from the solution, the Rust decoder (probably) only the missing ones. The Bend figure is the call only: the verification against the source, which the
     earlier version of this page had inside the clock, is outside now (so old and new decode numbers differ by that: the "before" table below is re-measured with the same harness).
* Bend: `tools/bench/bench.bend` (mode 0: `Codec.encoder_auto` / `Codec.symbols_auto` / `Codec.decode_auto`; mode 1: `Codec.encoder_flat_auto` + `Codec.symbols_flat`), native binary, IO `main`, wall clock via
  `IO.now`, `--threads 1`, 8 and 12. Rust: `tools/bench_rs` (single-threaded; the crate has no parallel solver), `Instant`.
  Minimum of 7 runs, each run a fresh process; the single-thread Bend runs and all Rust runs are pinned to ONE Cortex-A720 core (`PIN=0`, cpu0, 2.6 GHz), the 8-thread runs to the 8 big cores, the 12-thread runs
  are not pinned. Row construction of the Bend matrix is included in setup/decode (3 ms at K = 1000, 11 ms at K = 4000). The box was lightly loaded (load average 2-3 from other jobs); the Rust numbers move by 10-30 % between
  runs (K = 1000, T = 16 cold: 2.4 - 5.0 ms in different runs), so ratios are good to about that.
* Reproduce: `PIN=0 tools/bench/run.sh 7` (writes `build/bench_results.txt`, ~5 minutes), tables with `tools/bench/table.py`.

## Results (milliseconds, min of 7; "Bend/Rust" = slowdown factor of Bend)

Current code (this work: flat phase 1, program interpreter, sliced apply / decode / symbols as one parallel region, linear flat encoder), clang 14. "Bend n thr" = the tree API
(`Codec.encoder_auto` / `symbols_auto` / `decode_auto`), "flat API" = `Codec.encoder_flat_auto` + `symbols_flat` (docs/codec.md). 1 thread and Rust on cpu0 (the fastest A720, 2.6 GHz),
2-8 threads on the 8 big cores, 12 threads unpinned. Rust is single-threaded (the crate has no parallel solver), so its column is the same in every thread count.

### Encoder setup, Rust cold (fresh process: plan generation = the solve)
| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 1 thr flat API (ms) | Bend/Rust | Bend 8 thr (ms) | Bend/Rust | Bend 8 thr flat API (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust | Bend 12 thr flat API (ms) | Bend/Rust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.4 | 1.0 | 2.5x | 1.0 | 2.5x | 2.0 | 5.0x | 2.0 | 5.0x | 6.0 | 15.0x | 2.0 | 5.0x |
| 100 | 1024 | 0.8 | 5.0 | 6.2x | 3.0 | 3.8x | 5.0 | 6.2x | 5.0 | 6.2x | 7.0 | 8.8x | 6.0 | 7.5x |
| 1000 | 16 | 3.1 | 11 | 3.5x | 9.0 | 2.9x | 11 | 3.5x | 13 | 4.2x | 15 | 4.8x | 13 | 4.2x |
| 1000 | 1024 | 5.3 | 40 | 7.5x | 37 | 7.0x | 20 | 3.8x | 19 | 3.6x | 21 | 4.0x | 21 | 4.0x |
| 4000 | 16 | 9.2 | 41 | 4.5x | 38 | 4.1x | 48 | 5.2x | 48 | 5.2x | 52 | 5.7x | 44 | 4.8x |
| 4000 | 1024 | 22 | 183 | 8.2x | 167 | 7.5x | 87 | 3.9x | 83 | 3.7x | 85 | 3.8x | 86 | 3.8x |
| 10000 | 16 | 27 | 117 | 4.3x | 113 | 4.2x | 120 | 4.4x | 109 | 4.0x | 127 | 4.7x | 111 | 4.1x |
| 10000 | 1024 | 58 | 485 | 8.4x | 445 | 7.7x | 226 | 3.9x | 211 | 3.6x | 234 | 4.0x | 217 | 3.7x |
### Encoder setup, Rust warm (plan cached, only replayed)
| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 1 thr flat API (ms) | Bend/Rust | Bend 8 thr (ms) | Bend/Rust | Bend 8 thr flat API (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust | Bend 12 thr flat API (ms) | Bend/Rust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.0 | 1.0 | >20x | 1.0 | >20x | 2.0 | >40x | 2.0 | >40x | 6.0 | >120x | 2.0 | >40x |
| 100 | 1024 | 0.3 | 5.0 | 16.7x | 3.0 | 10.0x | 5.0 | 16.7x | 5.0 | 16.7x | 7.0 | 23.3x | 6.0 | 20.0x |
| 1000 | 16 | 0.2 | 11 | 55.0x | 9.0 | 45.0x | 11 | 55.0x | 13 | 65.0x | 15 | 75.0x | 13 | 65.0x |
| 1000 | 1024 | 3.0 | 40 | 13.3x | 37 | 12.3x | 20 | 6.7x | 19 | 6.3x | 21 | 7.0x | 21 | 7.0x |
| 4000 | 16 | 0.5 | 41 | 82.0x | 38 | 76.0x | 48 | 96.0x | 48 | 96.0x | 52 | 104.0x | 44 | 88.0x |
| 4000 | 1024 | 12 | 183 | 15.0x | 167 | 13.7x | 87 | 7.1x | 83 | 6.8x | 85 | 7.0x | 86 | 7.0x |
| 10000 | 16 | 1.3 | 117 | 90.0x | 113 | 86.9x | 120 | 92.3x | 109 | 83.8x | 127 | 97.7x | 111 | 85.4x |
| 10000 | 1024 | 30 | 485 | 15.9x | 445 | 14.6x | 226 | 7.4x | 211 | 6.9x | 234 | 7.7x | 217 | 7.1x |
### Generate 1000 repair symbols
| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 1 thr flat API (ms) | Bend/Rust | Bend 8 thr (ms) | Bend/Rust | Bend 8 thr flat API (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust | Bend 12 thr flat API (ms) | Bend/Rust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.2 | 0.0 | 0.0x | 0.0 | 0.0x | 0.0 | 0.0x | 0.0 | 0.0x | 0.0 | 0.0x | 0.0 | 0.0x |
| 100 | 1024 | 0.8 | 7.0 | 8.8x | 3.0 | 3.8x | 2.0 | 2.5x | 3.0 | 3.8x | 2.0 | 2.5x | 3.0 | 3.8x |
| 1000 | 16 | 0.6 | 1.0 | 1.7x | 0.0 | 0.0x | 1.0 | 1.7x | 0.0 | 0.0x | 1.0 | 1.7x | 0.0 | 0.0x |
| 1000 | 1024 | 1.2 | 13 | 10.8x | 2.0 | 1.7x | 4.0 | 3.3x | 2.0 | 1.7x | 4.0 | 3.3x | 3.0 | 2.5x |
| 4000 | 16 | 0.7 | 1.0 | 1.4x | 0.0 | 0.0x | 2.0 | 2.9x | 1.0 | 1.4x | 1.0 | 1.4x | 0.0 | 0.0x |
| 4000 | 1024 | 1.9 | 47 | 24.7x | 3.0 | 1.6x | 12 | 6.3x | 2.0 | 1.1x | 11 | 5.8x | 3.0 | 1.6x |
| 10000 | 16 | 1.0 | 2.0 | 2.0x | 0.0 | 0.0x | 2.0 | 2.0x | 0.0 | 0.0x | 2.0 | 2.0x | 1.0 | 1.0x |
| 10000 | 1024 | 2.7 | 117 | 43.3x | 3.0 | 1.1x | 21 | 7.8x | 3.0 | 1.1x | 25 | 9.3x | 3.0 | 1.1x |
### Decode from K symbols (7/8 repair)
| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 8 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.4 | 1.0 | 2.5x | 1.0 | 2.5x | 1.0 | 2.5x |
| 100 | 1024 | 0.6 | 3.0 | 5.0x | 3.0 | 5.0x | 4.0 | 6.7x |
| 1000 | 16 | 2.8 | 8.0 | 2.9x | 9.0 | 3.2x | 11 | 3.9x |
| 1000 | 1024 | 5.5 | 33 | 6.0x | 19 | 3.5x | 20 | 3.6x |
| 4000 | 16 | 9.9 | 41 | 4.1x | 41 | 4.1x | 42 | 4.2x |
| 4000 | 1024 | 24 | 157 | 6.6x | 100 | 4.2x | 98 | 4.1x |
| 10000 | 16 | 26 | 123 | 4.7x | 124 | 4.7x | 125 | 4.7x |
| 10000 | 1024 | 64 | 450 | 7.0x | 292 | 4.5x | 291 | 4.5x |

### The same tables with clang 19 (`CLANG_DIR=<dir with clang -> clang-19> PIN=0 tools/bench/run.sh 7`)
Single-thread setup / decode are 5-8 % faster at T = 1024 and up to 25 % at T = 16 with clang 19 (array tail loops are 20 % slower, list and tree code up to 1.9x faster, docs/scaling.md H); only the
setup table is repeated here:

#### Encoder setup, Rust cold (fresh process: plan generation = the solve)
| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 1 thr flat API (ms) | Bend/Rust | Bend 8 thr (ms) | Bend/Rust | Bend 8 thr flat API (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust | Bend 12 thr flat API (ms) | Bend/Rust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.4 | 0.0 | 0.0x | 1.0 | 2.5x | 2.0 | 5.0x | 2.0 | 5.0x | 3.0 | 7.5x | 2.0 | 5.0x |
| 100 | 1024 | 0.7 | 4.0 | 5.7x | 4.0 | 5.7x | 5.0 | 7.1x | 5.0 | 7.1x | 7.0 | 10.0x | 5.0 | 7.1x |
| 1000 | 16 | 3.1 | 10 | 3.2x | 11 | 3.5x | 10 | 3.2x | 11 | 3.5x | 15 | 4.8x | 12 | 3.9x |
| 1000 | 1024 | 5.2 | 38 | 7.3x | 35 | 6.7x | 19 | 3.7x | 19 | 3.7x | 20 | 3.8x | 21 | 4.0x |
| 4000 | 16 | 9.4 | 40 | 4.3x | 38 | 4.0x | 48 | 5.1x | 46 | 4.9x | 53 | 5.6x | 40 | 4.3x |
| 4000 | 1024 | 25 | 171 | 6.8x | 157 | 6.3x | 83 | 3.3x | 83 | 3.3x | 86 | 3.4x | 80 | 3.2x |
| 10000 | 16 | 32 | 111 | 3.5x | 107 | 3.3x | 120 | 3.8x | 114 | 3.6x | 127 | 4.0x | 116 | 3.6x |
| 10000 | 1024 | 55 | 452 | 8.2x | 413 | 7.5x | 218 | 3.9x | 205 | 3.7x | 224 | 4.0x | 228 | 4.1x |

### Before this work (same harness, same machine state, commit 7b05050; ms, thread count 1 / 8 / 12)
The old library, measured with this page's harness (repair = the call only; decode without the verification, which the previous version of this page had inside the clock). No column changes with the
thread count: nothing in one block scaled.

| K | T | setup 1 / 8 / 12 thr | repair 1 / 8 / 12 thr | decode 1 / 8 / 12 thr |
|---|---|---|---|---|
| 100 | 16 | 2 / 3 / 4 | 0 / 0 / 0 | 3 / 2 / 2 |
| 100 | 1024 | 5 / 8 / 7 | 6 / 7 / 7 | 5 / 6 / 5 |
| 1000 | 16 | 28 / 32 / 34 | 0 / 1 / 0 | 28 / 28 / 30 |
| 1000 | 1024 | 61 / 62 / 64 | 14 / 14 / 14 | 55 / 54 / 55 |
| 4000 | 16 | 146 / 147 / 158 | 1 / 1 / 1 | 159 / 153 / 153 |
| 4000 | 1024 | 302 / 300 / 303 | 47 / 49 / 50 | 299 / 296 / 298 |
| 10000 | 16 | 442 / 453 / 451 | 2 / 2 / 2 | 531 / 507 / 517 |
| 10000 | 1024 | 888 / 883 / 873 | 128 / 125 / 124 | 973 / 953 / 949 |

### Reading the new numbers (honest summary, details in docs/scaling.md)
* **One thread:** setup K = 1000 / 4000 / 10000, T = 1024: 61 / 302 / 888 ms -> 37 / 167 / 445 ms with the flat API (Bend/Rust 7.0x / 7.5x / 7.7x; it was 12.6x / 15.2x / 15.5x); T = 16: 28 / 146 / 442 -> 9 / 38 / 113 ms
  (2.9x / 4.1x / 4.2x of Rust; it was 12.5x / 17x / 19x). Decode K = 1000 / 4000 / 10000, T = 1024: 55 / 299 / 973 -> 33 / 157 / 450 ms. Repair of 1000 symbols at T = 1024 (K = 1000 / 4000 / 10000): 14 / 47 / 128 ->
  2 / 3 / 3 ms with the flat API (Rust 1.2 / 1.9 / 2.7: 1.1-1.7x), 13 / 47 / 117 ms through the tree API (it converts to and from trees on every call).
* **Threads, one block:** T = 1024 setup 38 -> 21 ms (K = 1000) and 170 -> 80 ms (K = 4000) at 8 threads (flat API), decode 33 -> 19 and 157 -> 100; the symbol side alone (apply) scales 2.9x / 3.6x; the
  rest of the block (row construction, plan: phase 1 + phase 2, program compile) is sequential: at T = 16 nothing scales (K = 1000: 9 ms at 1 thread, 11 at 8).
  12 threads are never better than 8 (the 4 Cortex-A520 are 3-4x slower and tasks are never moved).
* "Rust warm" (cached plan) is what a long-running Rust process pays for later blocks. Bend has the same mechanism (`Codec.encoder_plan` + `encode_with_plan[_flat]`, docs/plan_apply.md); the
  warm table compares Rust's replay with Bend's whole setup, so it understates Bend's warm path (a block with a ready plan skips the 10 / 49 ms plan and the rows).

## Reading the numbers (the parts of the earlier analysis that are still true)
* No hiding the rest of the gap: the Rust crate is mature and SIMD-optimised (NEON nibble-table `vqtbl1q_u8` kernels for XOR and multiply-add, a cached encoding plan, `u8` data in contiguous memory); this one is pure Bend.
* **The remaining symbol-arithmetic gap is SIMD.** On flat `Array<U32>` the Bend kernels run at C scalar-table parity (docs/profile.md
  section 4: multiply-add 2.9-3.4 ns/word against 2.8 for scalar C with the same table; XOR 1.1 ns/word, 3.5 ns per op at 4 words = C),
  but the Rust crate and the C NEON model do 16 octets per instruction: multiply-add 0.38 ns/word, XOR 0.16, i.e. 7-9x and 5-7x less. Bend 2.0.34
  has no SIMD/vector type, no `U8`/`U64`, and `Array` access costs a runtime operation per slot (1-2 ns, C: ~0.3). That is the whole difference on the symbol side; it is not a layout problem any more.
  About half of the K = 1000 program is multiply-adds (the 10 dense HDPC rows over all pivots and the dense tail solution; docs/scaling.md E3), which is where the SIMD gap is widest.
* **Where one block's time goes now** (K = 1000 / 4000, T = 1024, 1 thread, ms): rows 3 / 11, plan 10 / 49 (phase 1 on flat arrays; phase 2 4 / 24), program compile 2 / 9, apply 25 / 118, read-out into `Vec` trees (tree API only) 5 / 20.
  At T = 16 the whole solve is the plan, in Bend and in Rust (Rust cold solve 3 ms at K = 1000): the factor 3-4x is the plan (phase 2 and the list-shaped `Plan`) against Rust's tuned sparse structures.
* **Kernel-level check of "on par with C"** (`tools/profile/mb_arena.bend`, one array holding symbols and the 64K product table,
  10M words per measurement, ns per word): XOR 1.1; multiply-add by the 64K table 3.4; bit-sliced SWAR with hoisted `c * alpha^i` 4.7
  (loses by 1.4x); the Nat-fuel SWAR loop (`G.mulw`) 10. So the table is the best pure-Bend multiply in the arena setting and is what
  `Solver.apply` and the plan use (SWAR below 8 words per symbol, where building the table costs more than it saves).
* **Repair generation (T = 1024)**: with the tree API (`Codec.symbols`) it is conversion, not arithmetic: the XOR loops take 2.5 ms for K = 1000, N = 1000, but `Enc` is `Data` (cannot hold an `Array`), so every call copies the intermediate
  `Vec` trees into a flat array and reads every result out into trees. The linear flat API (`EncF`, docs/codec.md) keeps the solved arena and generates into flat arrays: 2-3 ms, 1.1-1.7x of Rust.
* **Threads:** see docs/scaling.md. The earlier version of this page said "12 threads no longer change the numbers": true then (slicing lost), not any more: one block's symbol side is one parallel region (3-3.6x of the apply at 8 threads,
  setup 1.8-2.1x, decode 1.4-1.7x at T = 1024); T = 16 and the plan stay sequential. 12 threads are never better than 8 here (the 4 Cortex-A520 cores are 3-4x slower and the runtime never moves a task).
  A parallel Bend process also pays a few ms of thread-pool start-up once (K = 100, T = 16: 1 ms at 1 thread, 2-6 ms at 8-12).
* **The 12-thread anomalies of the older tables are explained** (docs/profile.md section 6, refined in docs/scaling.md rule 4): non-tail calls inside a def that contains a fork heap-allocate a continuation task at `--threads` > 1.
  The tree-shaped code that remains (`G.Vec` ops, read-out) pays it; the flat code does not.

## Caveats
* Single machine, heterogeneous cores, one run configuration; timings vary +-10-30 % between runs (the tables are min of 7). Not tuned: no
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
