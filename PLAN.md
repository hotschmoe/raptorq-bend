# Plan
Wave 1 (independent modules, parallel):
- A. `src/gf256.bend` — GF(256) (RFC 5.7) exp/log tables, add/mul/div, octet vector ops (U32 elems), GF(2) bitwise; laws (field axioms where provable).
- B. `src/tables.bend` + `tools/` — RFC 5.5 rand tables V0–V3, 5.6 systematic-index table (K', J, S, H, W), `Rand`, `Deg`, `Tuple`; cross-checked vs Rust ref.
- C. `tools/vectors/` — Rust harness on `ref/raptorq-rs` emitting golden vectors (constraint matrix rows, intermediate symbols, encoded symbols, decode cases) as plain text for Bend tests.
Wave 2: constraint matrix (5.3.3.3), LT/PI encode (5.3.5), intermediate-symbol solver (5.4.2, inactivation decoding), encoder, decoder, parallelization, laws (encode/decode roundtrip), benches.
