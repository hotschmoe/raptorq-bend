# Benchmarks: Bend codec vs the Rust `raptorq` crate

Honest comparison of this repo's Bend implementation against cberner/raptorq 2.0.1 (the vendored copy in
`tools/vectors/vendor/raptorq`, which is what the golden vectors come from). Both are bit-exact RFC 6330 for these inputs
(decoded output is verified equal to the source in every run, `ok=1`).

## Setup
* Machine: aarch64, 12 cores (big.LITTLE-style cix SoC: Cortex-A720 up to 2.6 GHz + Cortex-A520 up to 1.8 GHz, i.e. the 12
  cores are NOT equal), 30 GB RAM, Linux 6.6. Debian clang 14.0.6 (`/usr/bin/clang`) builds the Bend binaries, Bend 2.0.34,
  rustc 1.96.0 `--release` (opt-level 3, LTO, no `target-cpu=native`).
* Workload (single source block, systematic code, one symbol = T octets, K source symbols of LCG data):
  1. **setup** = computing the intermediate symbols from the K source symbols (RFC 5.3.3.4; the matrix solve);
  2. **repair** = generating N = 1000 repair symbols from the intermediate symbols;
  3. **decode** = recovering the K source symbols from exactly K received symbols, 7 of 8 of them repair symbols (the hard case).
* Bend: `tools/bench/bench.bend` (`Codec.encoder_auto` / `Codec.decode_auto`), native binary, IO `main`, wall clock via `IO.now`,
  `--threads 1` and `--threads 12`. Rust: `tools/bench_rs` (single-threaded; the crate has no parallel solver), `Instant`.
  Minimum of 3 runs, each run is a fresh process. Row construction of the Bend matrix is included in setup/decode (4 ms at K=1000).
* Reproduce: `tools/bench/run.sh 3` (writes `build/bench_results.txt`). Total about 3 minutes.

## Results (milliseconds, min of 3; "Bend/Rust" = slowdown factor of Bend)

### Encoder setup, Rust cold (fresh process: plan generation = the solve)

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.3 | 4.0 | 13x | 5.0 | 17x |
| 100 | 1024 | 0.7 | 27 | 39x | 10 | 14x |
| 1000 | 16 | 3.9 | 56 | 14x | 52 | 13x |
| 1000 | 1024 | 6.8 | 287 | 42x | 105 | 15x |
| 4000 | 16 | 12 | 300 | 26x | 300 | 26x |
| 4000 | 1024 | 26 | 1419 | 55x | 611 | 24x |
| 10000 | 16 | 33 | 941 | 28x | 963 | 29x |
| 10000 | 1024 | 74 | 4066 | 55x | 2046 | 28x |

### Encoder setup, Rust warm (plan cached, only replayed)

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.0 | 4.0 | >40x | 5.0 | >50x |
| 100 | 1024 | 0.3 | 27 | 90x | 10 | 33x |
| 1000 | 16 | 0.1 | 56 | 560x | 52 | 520x |
| 1000 | 1024 | 3.7 | 287 | 78x | 105 | 28x |
| 4000 | 16 | 0.6 | 300 | 500x | 300 | 500x |
| 4000 | 1024 | 13 | 1419 | 113x | 611 | 48x |
| 10000 | 16 | 1.4 | 941 | 672x | 963 | 688x |
| 10000 | 1024 | 30 | 4066 | 133x | 2046 | 67x |

### Generate 1000 repair symbols

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.2 | 4.0 | 20x | 5.0 | 25x |
| 100 | 1024 | 0.9 | 83 | 92x | 142 | 158x |
| 1000 | 16 | 0.6 | 4.0 | 7x | 5.0 | 8x |
| 1000 | 1024 | 1.5 | 87 | 58x | 161 | 107x |
| 4000 | 16 | 1.0 | 5.0 | 5x | 6.0 | 6x |
| 4000 | 1024 | 2.0 | 111 | 56x | 278 | 139x |
| 10000 | 16 | 1.0 | 6.0 | 6x | 7.0 | 7x |
| 10000 | 1024 | 2.5 | 130 | 52x | 333 | 133x |

### Decode from K symbols (7/8 repair)

| K | T | Rust (ms) | Bend 1 thr (ms) | Bend/Rust | Bend 12 thr (ms) | Bend/Rust |
|---|---|---|---|---|---|---|
| 100 | 16 | 0.4 | 5.0 | 12x | 4.0 | 10x |
| 100 | 1024 | 0.7 | 35 | 50x | 83 | 119x |
| 1000 | 16 | 3.0 | 55 | 18x | 59 | 20x |
| 1000 | 1024 | 6.8 | 408 | 60x | 322 | 47x |
| 4000 | 16 | 11 | 401 | 36x | 436 | 39x |
| 4000 | 1024 | 24 | 2335 | 99x | 2135 | 91x |
| 10000 | 16 | 26 | 1457 | 55x | 1534 | 58x |
| 10000 | 1024 | 63 | 6961 | 110x | 6646 | 105x |

## Reading the numbers
* **Bend is 13-55x slower than Rust for the solve and 10-120x for decode.** There is no hiding this; the Rust crate is a mature,
  heavily optimised implementation (byte-slice symbols with optimised GF(256) kernels, a pre-computed encoding plan that is
  cached per K, sparse/dense matrix specialisations, `u8` data in contiguous memory). The Bend one is new, represents a symbol as a
  tree of boxed 32-bit words (24-40 bytes of heap per word, see docs/perf.md section 3) and has no SIMD.
* "Rust cold" is the apples-to-apples solve (a fresh process must generate the plan = run the elimination); "Rust warm" is what
  a long-running Rust process pays for the second and later blocks with the same K (the plan is cached and only replayed on the
  new data), where Bend has no equivalent yet (an operation-log replay is listed as future work).
* The factor grows with T (13-30x at T=16, 40-55x at T=1024 single-threaded): at small T the cost is the symbol-independent matrix
  work (inactivation, pivoting), which Bend does at a competitive-ish 13-30x; at large T it is the per-word cost of symbol XOR/mul-add.
* **Threads:** `--threads 12` helps only where `Solver.solve_auto` slices the symbols (T >= 256): setup 2.0-2.7x faster at
  T=1024 (K=1000: 287 -> 105 ms, K=10000: 4.07 -> 2.05 s). At T=16 it is neutral (the solver is sequential there by design, see
  docs/perf.md: parallel regions cost ~0.3 ms each in this runtime and sequential phases dominate). Decode at T=1024 gains little
  (1.0-1.3x): its system has more symbol-independent elimination work that every slice repeats.
* **Generating repair symbols is slower with 12 threads at T=1024** (e.g. K=1000: 87 -> 161 ms for 1000 symbols). Cause not
  investigated beyond noting that `Codec.symbols` is the same code in both cases and only the runtime's thread count differs
  (the parallel Vec operations in `gf256` fork at 4096 words only, so this is probably runtime/allocation contention). With
  small T the cost is negligible (4-7 ms per 1000 symbols). Run the repair stage with `--threads 1` if you need it fast.
* Rust's `repair` numbers include copying each symbol out into an `EncodingPacket`; Bend's include forcing every word.
* A parallel Bend process pays about 25-30 ms of thread-pool start-up once (visible at K=100 T=1024: setup 27 ms -> 10 ms is
  still a win, the decode 35 -> 83 ms is a loss; the decode figure at K=100 T=1024 12 threads includes that start-up).

## Caveats
* Single machine, heterogeneous cores, one run configuration; timings vary +-10 % (the table is min of 3). Not tuned: no
  `target-cpu=native` for Rust, default Bend flags.
* Rust numbers are for the vendored 2.0.1 sources with the `std` feature (plan cache on); the vendored copy is unchanged except
  the intermediate-symbol accessor (tools/vectors/vendor/README.md).
* The workload (7/8 repair decode, LCG data) is one point; the decoder time depends on the received pattern.
* Bend's `Codec.decode` recomputes all K source symbols from the intermediate symbols (it does not copy the received source
  symbols), the Rust decoder (probably, not verified) keeps the received source symbols and only recomputes the missing ones; this accounts for part of
  the decode gap at T=1024 (K source symbol re-encodings, about 8x the repair-generation cost above: ~0.1 s at K=10000).
* Peak memory was not measured here (solver.md/perf.md: 288 MB / 942 MB at K'=56403, T=16 / 1024; Rust not measured).
