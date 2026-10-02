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
  * speed: 7-19x slower than the Rust crate for the solve, 7-25x for decode, 20-60x for generating T = 1024 repair symbols
    (`docs/benchmarks.md`; pure Bend, no SIMD, no foreign code);
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
Native binary, aarch64 12 cores (one Cortex-A720 core for the 1-thread and Rust numbers), K source symbols, 7/8 of the decode input repair
symbols (min of 3, ms; details and caveats in `docs/benchmarks.md`). Bend/Rust = slowdown factor of Bend (1 thread). Pure Bend: symbols are
slices of one flat `Array<U32>` with a 64K product table, tail-recursive loops (`src/flat.bend`).

| K | T | Rust setup | Bend setup 1 / 12 thr | Bend/Rust | Rust decode | Bend decode 1 / 12 thr | Bend/Rust |
|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.3 | 2 / 6 | 6.7x | 0.3 | 3 / 2 | 10x |
| 100 | 1024 | 0.6 | 6 / 12 | 10x | 0.6 | 8 / 8 | 13x |
| 1000 | 16 | 2.4 | 30 / 34 | 12x | 2.1 | 31 / 30 | 15x |
| 1000 | 1024 | 5.4 | 68 / 72 | 13x | 5.9 | 93 / 91 | 16x |
| 4000 | 16 | 9.9 | 168 / 168 | 17x | 10 | 211 / 205 | 20x |
| 4000 | 1024 | 23 | 354 / 354 | 15x | 27 | 499 / 491 | 19x |
| 10000 | 16 | 30 | 557 / 536 | 19x | 30 | 734 / 724 | 25x |
| 10000 | 1024 | 69 | 1069 / 1049 | 15x | 81 | 1541 / 1510 | 19x |

Before the flat-symbol work (symbols as trees of boxed words) the same table read 13-55x (solve) and 12-110x (decode). The gap that is left is
SIMD (the Rust crate uses NEON kernels; Bend 2 has no vector or narrow types: the Bend multiply-add kernel is at scalar-C parity,
3.4 ns/word, but 7-9x from NEON) and our phase-1 bookkeeping. 12 threads no longer help: the symbol work is too cheap to slice below
2^23 words (docs/benchmarks.md, docs/plan_apply.md).

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
