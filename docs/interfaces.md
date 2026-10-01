# Module interfaces (wave 2+). Agents may refine internals but must keep these public signatures, or update this file and say so.

Shared types (src/types.bend, owned by wave-2 agent D; agent E imports it):
- `Sym`   = `Vec` from src/gf256.bend (packed symbol of T octets, T padded to a multiple of 4 inside; remember the true T separately).
- `Row`   = `Row{ cols: List<&2, Term>, rhs: Sym }`, `Term = Term{col: U32, coef: U32}` (coef is a GF(256) octet; 1 for binary entries). Row means: sum(coef_i * C[col_i]) = rhs.
- `Rcv{esi: U32, sym: Sym}` (IMPLEMENTED, replaces the `(esi, Sym)` tuple of `received_rows`). Accessors `Term.col/coef`, `Row.cols/rhs`. All three types are Data.
- Imports are `import ../src/types.bend as Y` (then `Y.Row{..}`, `Y.Term{..}`) and `G.Vec` for symbols.

Constraints (src/constraints.bend, agent D), per RFC 5.3.3.3 / 5.3.5.3 / 5.3.5.4:
- IMPLEMENTED as plain defs of src/constraints.bend (`import ../src/constraints.bend as C`; `C.fixed`, ...). `t` is the symbol size in OCTETS (U32); rhs symbols are ceil(t/4) packed words. Rows in `fixed` are S LDPC then H HDPC rows; `source_rows` ascends by ISI; `received_rows` returns received rows in reverse input order then the K'-K padding rows; `lt_terms` order is unspecified. Extras: `C.zero(t)`, `C.index(inter) -> C.ITree` (O(log L) lookup), `C.encode_idx(sp, tree, isi)`, `C.isi_of(esi, k, kp)`. Lists of symbols are `List<&2, G.Vec>`; `recv` is `List<&2, Y.Rcv>`.
- `Constraints.fixed(sp: T.SP, t: Nat/U32) -> List<Row>`   S LDPC rows + H HDPC rows (rhs = zero symbols). Column order follows the RFC (LT cols 0..W-1 incl. permanently inactivated at W..L-1 as in RFC).
- `Constraints.lt_terms(sp, isi: U32) -> List<Term>`      the columns of the LT/PI encoding of ISI (Enc[K',(C),(d,a,b,d1,a1,b1)]) all coef 1.
- `Constraints.source_rows(sp, source: List<Sym>) -> List<Row>`   K' rows for ISI 0..K'-1 (source symbols; ISI >= K padded with zero symbols).
- `Constraints.received_rows(sp, K, recv: List<(esi, Sym)>) -> List<Row>`  decoder rows: ESI < K -> ISI = ESI; ESI >= K -> ISI = ESI + (K'-K); plus the padding rows for ISI K..K'-1 with zero rhs.
- `Constraints.encode(sp, inter: List<Sym>, isi: U32) -> Sym`   evaluate LT/PI combination.

Solver (src/solver.bend, agent E), RFC 5.4.2 (inactivation decoding / Gaussian elimination over GF(256)):
- `Solver.solve(l: U32, rows: List<&2, Row>) -> Maybe<&2, List<&2, Sym>>`   returns C[0..l-1] or None if rank < l. IMPLEMENTED (inactivation decoding, docs/solver.md). Lists are `&2` (Data) lists, i.e. exactly what `Constraints.*` return and what `Constraints.encode/index` take (a `&1` list does not type-check against either). Works for any consistent system; need not follow the RFC's exact pivoting. Rows may list columns in any order, repeat a column (coefficients XOR) or carry zero coefficients. An inconsistent overdetermined system is NOT detected (extra rows that reduce to `0 = nonzero` are ignored).
- `Solver.solve_p(l: U32, p: U32, rows) -> Maybe<&2, List<&2, Sym>>`   same, with the hint that the last `p` columns are permanently inactive (RFC: p = L - W = `R.P(sp)`); `solve(l, rows) = solve_p(l, 0, rows)`. Pass the hint when you know it: it is faster and the answer is identical.
- `Solver.solve_dense(l, rows)`   plain Gauss-Jordan oracle (same signature); `Solver.inactive_count(l, p, rows) -> U32` diagnostics (size of the dense tail).

Encoder/decoder (wave 3): `Encoder`, `Decoder` composing the above.

Tests: Python generators in tools/ emit Bend fixture files (like tests/tables_test.bend) from tests/vectors/*.txt. Run via `bend tests/<x>_test.bend`; tests must exit non-zero on failure.
