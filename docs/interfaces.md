# Module interfaces (wave 2+). Agents may refine internals but must keep these public signatures, or update this file and say so.

Shared types (src/types.bend, owned by wave-2 agent D; agent E imports it):
- `Sym`   = `Vec` from src/gf256.bend (packed symbol of T octets, T padded to a multiple of 4 inside; remember the true T separately).
- `Row`   = `Row{ cols: List<&2, Term>, rhs: Sym }`, `Term = Term{col: U32, coef: U32}` (coef is a GF(256) octet; 1 for binary entries). Row means: sum(coef_i * C[col_i]) = rhs.

Constraints (src/constraints.bend, agent D), per RFC 5.3.3.3 / 5.3.5.3 / 5.3.5.4:
- `Constraints.fixed(sp: T.SP, t: Nat/U32) -> List<Row>`   S LDPC rows + H HDPC rows (rhs = zero symbols). Column order follows the RFC (LT cols 0..W-1 incl. permanently inactivated at W..L-1 as in RFC).
- `Constraints.lt_terms(sp, isi: U32) -> List<Term>`      the columns of the LT/PI encoding of ISI (Enc[K',(C),(d,a,b,d1,a1,b1)]) all coef 1.
- `Constraints.source_rows(sp, source: List<Sym>) -> List<Row>`   K' rows for ISI 0..K'-1 (source symbols; ISI >= K padded with zero symbols).
- `Constraints.received_rows(sp, K, recv: List<(esi, Sym)>) -> List<Row>`  decoder rows: ESI < K -> ISI = ESI; ESI >= K -> ISI = ESI + (K'-K); plus the padding rows for ISI K..K'-1 with zero rhs.
- `Constraints.encode(sp, inter: List<Sym>, isi: U32) -> Sym`   evaluate LT/PI combination.

Solver (src/solver.bend, agent E), RFC 5.4.2 (inactivation decoding / Gaussian elimination over GF(256)):
- `Solver.solve(l: U32, rows: List<Row>) -> Maybe<List<Sym>>`   returns C[0..l-1] or None if rank-deficient. Must work for any consistent system (tested on synthetic GF(256) systems) — it need not follow the RFC's exact pivoting, since the intermediate symbols are unique when A has full rank. Start with a correct dense baseline, then add the RFC's sparse/inactivation optimization; keep the baseline as a test oracle.

Encoder/decoder (wave 3): `Encoder`, `Decoder` composing the above.

Tests: Python generators in tools/ emit Bend fixture files (like tests/tables_test.bend) from tests/vectors/*.txt. Run via `bend tests/<x>_test.bend`; tests must exit non-zero on failure.
