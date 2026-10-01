# raptorq-bend

RFC 6330 RaptorQ in Bend 2. Goals, in order: (1) bit-exact RFC 6330 compliance, (2) showcase Bend (parallelism, `LAWS.bend` proofs), (3) clean readable code.

## Environment
- `export PATH="$HOME/.bend/bin:$PATH"`; `export BEND_NO_TELEMETRY=1`. Run `bend guide` (also `bend base`) BEFORE writing code; read `~/.bend/guide/*.md`.
- Run a file: `bend file.bend`. Check proofs: `bend PROOF.bend`. clang 15 only (no GPU/`!` — needs 19+); develop on the C/JS targets.
- Bend limits: numbers are Nat/U32/F32 only (no U8/U64 — store GF(256) octets as U32), affine values, no if/else (match on True/False), termination required, no mutual recursion, strings are slow.

## References (git-ignored, in `ref/`)
- `ref/rfc6330.txt` — the spec; the source of truth.
- `ref/raptorq-rs/` — cberner/raptorq (Rust, tested against the RFC); use it to generate/cross-check test vectors.
- `ref/raptorq-zig/` — author's old Zig port. UNVERIFIED, possibly wrong. Hints only; never trust over the RFC.

## Layout
- `src/` Bend modules (one concern per file, `import`-able). `tests/` Bend test programs. `tools/` generators (Rust/Python) for test vectors and tables. `docs/` notes.
- Each module with an invariant gets a `LAWS.bend`-style law + proof where feasible; don't block progress on hard proofs — mark TODO in `docs/proofs.md`.

## Rules
- Only touch files in your assigned area. Commit small, descriptive commits (don't push; the lead pushes).
- Every module ships with tests that run via `bend` and pass; report exact commands and output.
- Generated tables (RFC 5.5 V0–V3, 5.6 systematic indices) must be produced by a script in `tools/` from `ref/rfc6330.txt`, not hand-typed.
