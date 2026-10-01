# raptorq-bend

RFC 6330 (RaptorQ forward error correction) written natively in [Bend 2](https://github.com/bendlang/bend): an encoder and
decoder for a single source block, with a parallel (symbol-sliced) solver and correctness laws checked by the Bend compiler.

A RaptorQ code turns K source symbols into an unbounded stream of encoding symbols; the source is recoverable from (almost
always) any K of them, in any order. This repo implements the whole pipeline: code parameters and tables, constraint matrix,
inactivation-decoding solver over GF(256), systematic encoder and decoder.

## Status and conformance
* **Bit-exact with RFC 6330 and the Rust `raptorq` crate** (cberner/raptorq 2.0.1) on all test vectors: parameters, tuples,
  constraint-matrix rows, intermediate symbols, every encoding symbol (source and repair) of 18+5 (K,T) cases including odd
  symbol sizes, and 190 decode cases (15 where the reference decoder fails, where Bend also returns `None`). See
  `tests/vectors/README.md` (K = 1 .. 1000 incl. T = 4, 5, 16, 32).
* Single source block, `1 <= K <= 56403`; the full K' = 56403 system solves (15-36 s, `docs/perf.md`).
* **Limitations:**
  * no multi-block partitioning (Z > 1), no sub-blocking, no OTI / payload-id packet framing (RFC 4.3, 4.4);
  * no detection of corrupt symbols: an inconsistent overdetermined system is not noticed, the decoder returns the code word
    nearest the solver's choice;
  * speed: 13-55x slower than the Rust crate for the solve, up to ~100x for decode (`docs/benchmarks.md`);
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

## Performance
Native binary, aarch64 12 cores, K source symbols, 7/8 of the decode input repair symbols (min of 3, ms; details and caveats in
`docs/benchmarks.md`). Bend/Rust = slowdown factor of Bend (1 thread).

| K | T | Rust setup | Bend setup 1 / 12 thr | Bend/Rust | Rust decode | Bend decode 1 / 12 thr | Bend/Rust |
|---|---|---|---|---|---|---|---|
| 100 | 16 | 0.3 | 4 / 5 | 13x | 0.4 | 5 / 4 | 12x |
| 100 | 1024 | 0.7 | 27 / 10 | 39x | 0.7 | 35 / 83 | 50x |
| 1000 | 16 | 3.9 | 56 / 52 | 14x | 3.0 | 55 / 59 | 18x |
| 1000 | 1024 | 6.8 | 287 / 105 | 42x | 6.8 | 408 / 322 | 60x |
| 4000 | 16 | 12 | 300 / 300 | 26x | 11 | 401 / 436 | 36x |
| 4000 | 1024 | 26 | 1419 / 611 | 55x | 24 | 2335 / 2135 | 99x |
| 10000 | 16 | 33 | 941 / 963 | 28x | 26 | 1457 / 1534 | 55x |
| 10000 | 1024 | 74 | 4066 / 2046 | 55x | 63 | 6961 / 6646 | 110x |

The Rust crate is a mature, optimised implementation; this one is new (the solver went from 0.57 s to 53 ms at K=1000 in the
last optimisation round, `docs/perf.md`). Threads only help where symbols are sliced (T >= 256).

## Repository layout
```
src/            gf256 (symbol vectors), tables (RFC 5.5/5.6), rfc_funcs (Rand/Deg/Tuple, parameters), types, constraints
                (matrix rows, LT/PI encode), solver (inactivation decoding), raptorq (Codec), raptorq_demo, laws_defs
tests/          *_test.bend suites, generated fixtures, tests/vectors (golden vectors from the Rust crate), tests/vectors2
tools/          generators (Python/Rust) for tables, fixtures and vectors; tools/bench, tools/bench_rs (benchmarks)
docs/           codec, solver, perf, benchmarks, interfaces, constraints, gf256, tables, proofs
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
