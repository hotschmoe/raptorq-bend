# Plan
Wave 1 (independent modules, parallel):
- A. `src/gf256.bend` — GF(256) (RFC 5.7) exp/log tables, add/mul/div, octet vector ops (U32 elems), GF(2) bitwise; laws (field axioms where provable).
- B. `src/tables.bend` + `tools/` — RFC 5.5 rand tables V0–V3, 5.6 systematic-index table (K', J, S, H, W), `Rand`, `Deg`, `Tuple`; cross-checked vs Rust ref.
- C. `tools/vectors/` — Rust harness on `ref/raptorq-rs` emitting golden vectors (constraint matrix rows, intermediate symbols, encoded symbols, decode cases) as plain text for Bend tests.
Wave 2: constraint matrix (5.3.3.3), LT/PI encode (5.3.5), intermediate-symbol solver (5.4.2, inactivation decoding), encoder, decoder, parallelization, laws (encode/decode roundtrip), benches.

Wave 3: end-to-end codec (`src/raptorq.bend`: split/join, encoder, symbol/repair, decoder), demo, codec tests, vectors2.
Wave 4: solver performance (docs/perf.md: column index, sparse rows, elimination logs, symbol slicing `solve_par`/`solve_auto`),
laws/proofs (LAWS.bend, PROOF.bend, docs/proofs.md), codec integration of the auto-parallel solver, benchmarks, README.

## Status checklist
Done
- [x] GF(256) + symbol vectors (`src/gf256.bend`), tests exhaustive over all 256x256 pairs
- [x] RFC 5.5/5.6 tables and Rand/Deg/Tuple/parameters, generated from the RFC text, cross-checked vs the Rust crate
- [x] Constraint matrix (LDPC, HDPC, LT/PI rows), independently derived check vs the RFC (`tools/ref_constraints.py`)
- [x] Inactivation solver (RFC 5.4.2 style, own pivoting) + dense oracle; K = 56403 solves
- [x] Encoder/decoder, bit-exact against the Rust crate on all golden vectors (incl. failure cases)
- [x] Parallel solver: `solve_par` (symbol slicing), `solve_auto` (thread count), `Codec.encoder_auto` / `decode_auto`
- [x] Benchmarks vs the Rust crate (`docs/benchmarks.md`, `tools/bench`, `tools/bench_rs`), `scripts/test_all.sh`
- [x] README, LICENSE, `docs/interfaces.md` matching the code
- [x] Laws/proofs started (see `docs/proofs.md` for what is proven and what is TODO)
- [x] Flat symbol arenas (`src/flat.bend`; docs/profile.md R1/R3): repair generation, `Solver.apply`, the coefficient side of `Solver.plan`, decoder re-encode (solve 3-5x, decode 4-9x faster)

Not done
- [ ] Multi-block partitioning (Z > 1, RFC 4.4.1.2 / sub-blocking 4.3), OTI and payload-id framing
- [ ] Detection of corrupt/inconsistent symbols (overdetermined systems are not checked)
- [ ] Parity with the Rust crate's speed (currently 7-19x slower solve, 7-25x decode, 20-60x repair at T = 1024; remaining: SIMD and phase 1, docs/benchmarks.md)
- [ ] GPU target
- [ ] Remaining TODO proofs (GF(256) multiplication laws, solver correctness, encode/decode round trip)

## Future work
- **Multi-block**: partition function (RFC 4.4.1.2), per-block encoders/decoders run in parallel (blocks are independent: the
  easiest big parallel win), packet framing.
- **Operation-log replay for large T** (RFC 5.4.2.2 "operation vector"): solve the matrix once per K, record the row operations,
  replay them on the symbols (and on later blocks with the same K). Rust's cached encoding plan is exactly this; it is why its
  "warm" setup is 100-600x faster than ours (docs/benchmarks.md). Also cuts decode time at T >> 16 (docs/codec.md).
- **GPU target** when clang 19+ is available: the symbol slices of `solve_par` are the natural kernel granularity.
- **Graph-component phase-1 rule** (RFC 5.4.2.2 pivot choice): measured on the real systems at only a 4-10 % smaller dense tail
  (a few percent of runtime), so low priority (docs/perf.md section 2).
- Phase 1 + row bookkeeping (22 / 123 ms at K = 1000 / 4000, now the biggest T-independent cost): flat CSR rows instead of lists (docs/profile.md R6).
- A linear (non-`Data`) encoder type that keeps the symbol arena and hands out flat words: removes the copy-in and `Vec` read-out of `Codec.symbols` (about 13 of 17 ms at K = 1000, N = 1000, T = 1024).
- Upstream: per-call `seq` fast path for `--threads` > 1 (explains the old 12-thread anomalies), `Array.init` for linear elements, SIMD / narrow types (docs/profile.md section 7).
