# raptorq-bend

RFC 6330 (RaptorQ forward error correction) written natively in [Bend 2](https://github.com/bendlang/bend): an encoder and
decoder for single source blocks and for whole multi-block objects (RFC 4.3 / 4.4: Partition, OTI, sub-blocks, blocks encoded and decoded
in parallel), with a parallel (symbol-sliced) solver and correctness laws checked by the Bend compiler.

A RaptorQ code turns K source symbols into an unbounded stream of encoding symbols; the source is recoverable from (almost
always) any K of them, in any order. This repo implements the whole pipeline: code parameters and tables, constraint matrix,
inactivation-decoding solver over GF(256), systematic encoder and decoder.

## Status and conformance
* **Bit-exact with RFC 6330 and the Rust `raptorq` crate** (cberner/raptorq 2.0.1) on all test vectors: parameters, tuples,
  constraint-matrix rows, intermediate symbols, every encoding symbol (source and repair) of 18+5 (K,T) cases including odd
  symbol sizes, and 190 decode cases (15 where the reference decoder fails, where Bend also returns `None`). See
  `tests/vectors/README.md` (K = 1 .. 1000 incl. T = 4, 5, 16, 32).
* **Multi-block objects** (`src/blocks.bend`, `docs/multiblock.md`): Partition[I,J], the RFC 4.3 parameter derivation (T, Z, N from F, P', Al, WS, SS, K_L from Table 2),
  the 12-octet OTI and the payload id, Z <= 255 source blocks each cut into N sub-blocks, encode / decode of a whole object with the blocks as balanced
  divide-and-conquer tasks. Bit-exact against the crate on 11 multi-block objects (Z = 1 .. 11, ZL and ZS blocks, T = 4 .. 32, Al = 1 .. 8, N = 1 .. 5: every source and repair packet,
  33 loss scenarios spread over the blocks) and on 720 derived-parameter / 118 `Partition` / 40 `K_L` vectors (`tests/vectors3/README.md`). Limits: F < 4 GiB (U32).
* Per source block `1 <= K <= 56403`; the full K' = 56403 system solves in 7 s (T = 16) / 13 s (T = 1024) of wall time including two row
  builds, 1 thread, peak RSS 282 / 852 MB (`tests/solver_bench.bend` mode 5; was 15 / 36 s, `docs/perf.md`).
* **Limitations:**
  * packets are `Pkt{sbn, esi, sym}` records: only the OTI (12 octets) and the 4-octet payload id have a wire encoding (no ALC / FLUTE / UDP framing);
  * no detection of corrupt symbols: an inconsistent overdetermined system is not noticed, the decoder returns the code word
    nearest the solver's choice;
  * speed: 3-8x slower than the Rust crate for the solve and decode on one core (7-8x at T = 1024, 3-4x at T = 16), 1.1-1.7x for generating T = 1024 repair
    symbols with the flat API (`docs/benchmarks.md`; pure Bend, no SIMD, no foreign code); ONE block scales only partly over cores (below, `docs/scaling.md`);
  * the GPU target (`!`) needs clang 19+, which is not available here: everything is developed on the C (and JS) targets;
  * developed on aarch64 with clang 14. Native binaries need the system clang first in `PATH`:
    `export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH"` (the default `clang` on the dev box is a GPU-vendor build that fails with
    "unknown target triple x86_64"). Running with `bend file.bend` works either way.

## Quick start
```sh
# install Bend 2 (https://github.com/bendlang/bend; developed with 2.0.34):
curl -fsSL https://bend-lang.com/install.sh | sh   # installs to ~/.bend, sha256-verified
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1

bend src/raptorq_demo.bend                           # encode a text, drop every 4th symbol, decode it back
bend src/raptorq_demo.bend -o build/demo             # native binary (much faster)
bend src/blocks_demo.bend                            # a multi-block object (Z = 3, N = 4 sub-blocks) with losses in every block, decoded back
bend src/blocks_demo.bend -o build/blocks_demo && ./build/blocks_demo --threads 8 -- bench 64 1000 1024   # 64 blocks of K = 1000, T = 1024 octets
./build/demo --threads 12 -- bench 1000 3 1024       # K=1000 symbols of 1024 octets: encoder_auto + decode_auto

scripts/test_all.sh                                  # every tests/*_test.bend (+ proofs if scripts/check_proofs.sh exists)
bend tests/codec_test.bend                           # one suite (about 1 minute interpreted)
```
Always benchmark with an IO `main` and a native binary (`-o`); a non-IO `main` uses a much slower evaluator.
Rust comparison: `tools/bench/run.sh` (needs cargo).

## API summary
```bend
import ./src/raptorq.bend as Q
# data: List<&2, U32> of octets (each < 256)
src = Q.Codec.split(data, t)                         # K = ceil(len/t) source symbols of t octets (zero padded)
m   = Q.Codec.encoder(k, t, src)                     # Maybe<Enc>; runs the solver once
sym = Q.Codec.symbol(enc, esi)                       # ESI < K: source symbol, ESI >= K: repair symbol
out = Q.Codec.decode(k, t, received)                 # received: List<Y.Rcv{esi, sym}>, >= K symbols -> Maybe<List<Sym>>
bytes = Q.Codec.join(out, t, len)
# IO variants that slice long symbols over the threads (identical results):
m   <- Q.Codec.encoder_auto(k, t, src)
out <- Q.Codec.decode_auto(k, t, received)
```
Full signatures: `docs/interfaces.md`; codec details: `docs/codec.md`.

Multi-block objects (`import ./src/blocks.bend as B`, details and measurements in `docs/multiblock.md`):
```bend
oti = B.Blocks.params(f, p, al, ws, ss)              # Maybe<Oti>: T, Z, N from F, payload size P', alignment, working memory WS, SS (RFC 4.3)
oti = B.Blocks.oti(f, t, z, n, al)                   # Maybe<Oti>, validated;  B.Blocks.oti_bytes(oti) / oti_parse(bytes): the 12 octets of the OTI
p   = B.Blocks.partition(i, j)                       # Part{il, ish, jl, js} = RFC 4.4.1.2 Partition[I,J];  B.Blocks.layout(oti) -> Lay{kt, kl, ks, zl, zs}
obj = B.Blocks.encode_object(w, oti, data)           # Maybe<Obj>: every source block encoded, w = workers of the block tree (IO.thread_count())
sym = B.Blocks.symbol(obj, sbn, esi)                 # Maybe<Sym>: encoding symbol ESI of block SBN (ESI < K: the source symbol)
out = B.Blocks.decode_object(w, oti, pkts)           # pkts: List<Pkt{sbn, esi, sym}>, any order -> Maybe<bytes>
reps = B.Blocks.encode_repair(w, oti, n, B.Blocks.split_object(oti, data))   # n repair symbols of every block, on the flat arena (fastest)
```

## Performance
Native binary, aarch64 12 cores (one Cortex-A720 core, cpu0, for the 1-thread and Rust numbers; 8 threads = the 8 big cores), K source symbols, 7/8 of the decode input repair
symbols (min of 7, ms, box lightly loaded; details and caveats in `docs/benchmarks.md`). Bend/Rust = slowdown factor of Bend at one thread. Pure Bend: symbols are
slices of one flat `Array<U32>` with a 64K product table, tail-recursive loops (`src/flat.bend`), the plan compiled to a flat program, phase 1 on flat arrays. "flat API" = `Codec.encoder_flat_auto` (docs/codec.md).

| K | T | Rust setup | Bend setup 1 thr (flat API) / 8 thr | Bend/Rust at 1 thr | Rust decode | Bend decode 1 / 8 thr | Bend/Rust at 1 thr |
|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.4 | 1 / 2 | 2.5x | 0.4 | 1 / 1 | 2.5x |
| 100 | 1024 | 0.8 | 3 / 5 | 3.8x | 0.6 | 3 / 3 | 5.0x |
| 1000 | 16 | 3.1 | 9 / 13 | 2.9x | 2.8 | 8 / 9 | 2.9x |
| 1000 | 1024 | 5.3 | 37 / 19 | 7.0x | 5.5 | 33 / 19 | 6.0x |
| 4000 | 16 | 9.2 | 38 / 48 | 4.1x | 9.9 | 41 / 41 | 4.1x |
| 4000 | 1024 | 22 | 167 / 83 | 7.5x | 24 | 157 / 100 | 6.6x |
| 10000 | 16 | 27 | 113 / 109 | 4.2x | 26 | 123 / 124 | 4.7x |
| 10000 | 1024 | 58 | 445 / 211 | 7.7x | 64 | 450 / 292 | 7.0x |

Before this work (commit 7b05050, same harness): K = 1000, T = 1024 setup 61 ms (12.6x of Rust in the older table), K = 4000 302 ms, decode 55 / 299 ms, repair of 1000 symbols 14 / 47 ms (now 2-3 ms with the flat API, Rust 1.2 / 1.9),
and none of it changed with `--threads`. What changed: phase 1 and the row bookkeeping run on flat arrays (K = 4000 plan 152 -> 49 ms), the plan is compiled to a flat program (no list walks), the dense rows no longer go through a tree
fold, repair generation has a linear flat API, and the symbol side of one block runs as ONE parallel region.

**Does one block scale over cores?** Partly, and here is exactly why. Pure Bend *does* scale on one shape: a single balanced fork tree whose leaves allocate and own their arrays gets 6.5-7x at 8 threads in the scaling lab
(`docs/scaling.md`; 8 big + 4 little cores, so 12 threads are worth ~8.4 big cores and are never better than 8). One block gets 3-3.6x on its symbol side (apply) and 1.8-2.1x end to end for setup at T = 1024 (K = 1000: 38 -> 21 ms,
K = 4000: 170 -> 80 ms at 8 threads), 1.4-1.7x for decode, and nothing at T = 16: the rest of a block is a sequential chain (row construction, phase 1 + phase 2 of the plan, the program compile: 10 / 49 ms at K = 1000 / 4000) made of
steps of microseconds, while a parallel region reached from sequential code costs 0.15-0.3 ms in this runtime. What Bend would need: a region round of ~10 us (or work stealing inside a region) so that per-pivot Gauss-Jordan
and the dense-row corrections could fork, no heap-continuation penalty for defs that merely contain a fork, a safe read-only array sharing primitive (`Array.fork` exists but is `@unsafe` and fails the proof gate), and big-core
bias or work stealing for big.LITTLE chips. The remaining single-thread gap is SIMD (the Rust crate uses NEON kernels; Bend 2 has no vector or narrow types: the multiply-add kernel is at scalar-C parity, 3 ns/word, 7-9x from NEON)
and the sequential plan (T = 16: 3-4x of Rust).

**Multi-block objects scale across cores** (`docs/multiblock.md`): 64 blocks of K = 1000 symbols of T = 1024 octets (a 65 MB object), blocks as one balanced fork tree
(one task per block), one plan per K shared by all blocks; min of 5, 12-core aarch64 shared with other jobs (8 big + 4 little cores, so 12 threads are worth ~8.8 big cores):

| threads | encode + 879 repair symbols per block | speedup | decode from K symbols per block (7/8 repair) | speedup |
|---|---|---|---|---|
| 1 | 1933 ms | 1.00x | 2834 ms | 1.00x |
| 2 | 946 | 2.04x | 1169 | 2.42x |
| 4 | 517 | 3.74x | 654 | 4.33x |
| 8 (big cores) | 300 | 6.44x | 398 | 7.12x |
| 12 | 275 | 7.03x | 369 | 7.68x |

8 independent single-thread processes (no Bend scheduler, same box) reach 6.34x / 7.79x, so the block tree gets 100% / 91% of what the hardware allows here; 8 blocks only reach 4.7x (a ~50 ms
sequential part: the plan and starting the pool). The `!` call syntax gives the same curve as plain forks. One Rust core decodes this object in 378 ms (the Bend 8-thread run: 398 ms).

## Repository layout
```
src/            gf256 (symbol vectors), flat (flat Array<U32> symbols + kernels), tables (RFC 5.5/5.6), rfc_funcs (Rand/Deg/Tuple, parameters), types, constraints
                (matrix rows, LT/PI encode), solver (inactivation decoding), raptorq (Codec), raptorq_demo, blocks (multi-block objects: Partition, OTI,
                parallel block encode/decode), blocks_demo, laws_defs
tests/          *_test.bend suites, generated fixtures, tests/vectors (golden vectors from the Rust crate), tests/vectors2 (harder decodes), tests/vectors3 (multi-block objects)
tools/          generators (Python/Rust) for tables, fixtures and vectors; tools/bench, tools/bench_rs (benchmarks), tools/blocks_lab.bend + blocks_sweep.sh (multi-block scaling)
docs/           codec, solver, perf, benchmarks, interfaces, constraints, gf256, tables, proofs, multiblock (parallel multi-block objects)
scripts/        test_all.sh (and check_proofs.sh)
LAWS.bend, PROOF.bend   laws and their proofs (see below)
ref/            (git-ignored) RFC 6330 text and the reference implementations
```

## Laws and proofs
Bend can check theorems about the code with its own proof kernel (`bend PROOF.bend`). Which laws are proven, which are checked
exhaustively by tests instead and which are TODO is documented in [`docs/proofs.md`](docs/proofs.md).

## Acknowledgements and references
* [RFC 6330](https://www.rfc-editor.org/rfc/rfc6330): RaptorQ Forward Error Correction Scheme for Object Delivery (the
  source of truth, tables V0-V3 and the systematic-index table are generated from its text by `tools/`).
* [cberner/raptorq](https://github.com/cberner/raptorq) (Rust, Apache-2.0): reference for the golden vectors and the benchmark
  baseline (a copy is vendored under `tools/vectors/vendor`).
* The RFC-faithful, readable-first, test-vectors-in-the-repo style follows [smoltcp](https://github.com/smoltcp-rs/smoltcp).
* [Bend 2](https://github.com/bendlang/bend) and its guide.

License: MIT (`LICENSE`).
