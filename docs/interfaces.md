# Module interfaces (as implemented)

All signatures below are the real ones in `src/` (checked against the code at the time of writing). Modules are imported with
`import ../src/x.bend as X`; defs named `Mod.f` live in module `x.bend`, so a call looks like `X.Mod.f(..)`
(e.g. `Q.Codec.encoder(..)`, `S.Solver.solve_p(..)`), while plain defs are `C.fixed(..)`. Lists of data are `List<&2, ..>`
(duplicable "Data" lists). `+x` parameters are duplicable numbers. `t` is always the symbol size in OCTETS.

## Types (`src/types.bend`, `src/tables.bend`, `src/gf256.bend`)
- `G.Vec` (= `Sym`): packed symbol, ceil(T/4) big-endian U32 words as a balanced tree; the true T is carried separately.
- `Y.Term{col: U32, coef: U32}` (coef is a GF(256) octet, 1 for binary entries), `Y.Row{cols: List<&2, Term>, rhs: G.Vec}`
  = `sum(coef_i * C[col_i]) = rhs`, `Y.Rcv{esi: U32, sym: G.Vec}` (a received encoding symbol). All three are Data.
- `T.SP{kp, j, s, h, w, p1}`: code parameters of a K (RFC 5.6 Table 2); accessors `R.Kp(sp)`, `R.L(sp)`, `R.P(sp)` (`rfc_funcs.bend`).
- `R.params(k: U32) -> Maybe<&2, T.SP>`: `None` if K = 0 or K > 56403.

## Constraints (`src/constraints.bend`, RFC 5.3.3.3 / 5.3.5)
Plain defs (`C.fixed`, ...). Rows of `fixed` are S LDPC then H HDPC rows.
- `C.fixed(sp, t) -> List<&2, Y.Row>`: S LDPC + H HDPC rows, rhs = zero symbols.
- `C.lt_terms(sp, isi) -> List<&2, Y.Term>`: columns of the LT/PI combination of an ISI (order unspecified).
- `C.source_rows(sp, source: List<&2, G.Vec>) -> List<&2, Y.Row>`: K' rows for ISI 0..K'-1 (ISI >= K zero symbols).
- `C.received_rows(sp, k, recv: List<&2, Y.Rcv>) -> List<&2, Y.Row>`: ESI < K -> ISI = ESI, ESI >= K -> ISI = ESI + K' - K;
  plus the K'-K padding rows (zero rhs).
- `C.index(inter: List<&2, G.Vec>) -> C.ITree` (O(log L) lookup), `C.encode_idx(sp, tree, isi) -> G.Vec`,
  `C.encode(sp, inter, isi) -> G.Vec` (list version), `C.isi_of(esi, k, kp) -> U32`, `C.zero(t) -> G.Vec`.

## Flat symbols (`src/flat.bend`; docs/profile.md)
Symbols as slices of one `Array<U32>` (`Array` is linear: every def threads it through and returns it). `Flat.of_vec(v) -> Array<U32>`,
`Flat.to_vec(n, a) -> G.Vec` (round trip), `Flat.put_vec(v, base, a) -> Array`, `Flat.get_vec(a, base, n) -> Bv{v, a}`, kernels
`Flat.xr/cp/zr/ms/ma.loop(n, 0, db, sb[, c], a)` (a[db+j] ^= / = / 0 / c* / ^= c* a[sb+j], j < n), `Flat.encode_tree(sp, k, tr, esi0, n)` and
`Flat.encode_list(sp, k, inter, esi0, n)` (encoding symbols from the intermediate symbols; used by `Codec.symbols` / `Codec.decode`).

## Solver (`src/solver.bend`, RFC 5.4.2; see `docs/solver.md`, `docs/perf.md`)
All return `Maybe<&2, List<&2, G.Vec>>` = C[0..L-1] (`None` if rank < L), except `solve_auto` (IO) and `inactive_count`.
Rows may list columns in any order, repeat a column or carry zero coefficients. Inconsistent overdetermined systems are NOT
detected (extra rows reducing to `0 = nonzero` are ignored).
- `Solver.solve(l: U32, rows: List<&2, Y.Row>)`: `solve_p` with p = 0.
- `Solver.solve_p(l: U32, p: U32, rows)`: the last `p` columns are permanently inactive (`p = R.P(sp)`); sequential, the same
  speed with any `--threads`.
- `Solver.solve_par(l: U32, p: U32, d: U32, rows)`: same answer; the symbols are cut into 2^d word ranges solved as 2^d
  independent top-level tasks (d is capped by the symbol size; d = 0 is `solve_p`). Pays off for T >= 256 octets.
- `Solver.solve_auto(l: U32, p: U32, rows) -> IO(Maybe<&2, List<&2, G.Vec>>)`: `solve_par` with d = 0 below 256 octets,
  else `min(3, log2(IO.thread_count()))`. Needs an IO context (native binary: `./prog --threads N`).
- `Solver.plan(l, p, rows) -> Maybe<&2, Plan>`: symbol-independent part (rhs of the rows ignored, pass `G.VNil{}`), `None` if rank < l.
  `Plan` is Data (lists only; reusable, duplicable). `Solver.plan_rows(plan)` = number of rhs symbols, `Solver.plan_cols(plan)` = l.
- `Solver.apply(plan, rhs: List<&2, G.Vec>) -> List<&2, G.Vec>`: C[0..l-1]; `rhs` = exactly `plan_rows` symbols of one common length,
  one per row in the order the plan was made from. `Solver.apply_par(d, plan, rhs)` (2^d symbol slices in parallel),
  `Solver.apply_auto(plan, rhs) -> IO(List<G.Vec>)` (d from threads/symbol size). solve/solve_p/solve_par/solve_auto = plan + apply.
- `Solver.solve_dense(l, rows)`: plain Gauss-Jordan oracle (slow, for tests); `Solver.inactive_count(l, p, rows) -> U32`: size
  of the dense tail (diagnostics).

## Codec (`src/raptorq.bend`, RFC 5.3 / 5.4; see `docs/codec.md`)
Single source block, 1 <= K <= 56403. `Enc{k, t, sp, tr}` holds the parameters and the indexed intermediate symbols.
- `Codec.k_of(len: U32, t: U32) -> U32`
- `Codec.split(data: List<&2, U32>, t: U32) -> List<&2, G.Vec>`; `Codec.join(syms, t, len) -> List<&2, U32>`;
  `Codec.sym_bytes(sym, t) -> List<&2, U32>`
- `Codec.encoder(k, t, source: List<&2, G.Vec>) -> Maybe<&2, Enc>`: runs the solver once (pure, sequential)
- `Codec.encoder_auto(k, t, source) -> IO(Maybe<&2, Enc>)`: same result bit for bit, solver = `Solver.solve_auto`
- `Codec.symbol(enc, esi: U32) -> G.Vec` (alias `Codec.repair`); `Codec.symbols(enc, esi0: U32, n: U32) -> List<&2, G.Vec>`
- `Codec.decode(k, t, received: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>`: the K source symbols; `None` if fewer than K
  symbols, invalid K/T, or rank deficient
- `Codec.decode_auto(k, t, received) -> IO(Maybe<&2, List<&2, G.Vec>>)`: same result, solver = `Solver.solve_auto`

- Plans: `Codec.plan_for(k, esis) -> Maybe<&2, Plan>` (decoder, ESIs in the order the symbols will be given; `None` if < K or rank
  deficient), `Codec.encoder_plan(k)` (= plan_for(k, 0..k-1)), `Codec.encode_with_plan(k, t, plan, source) -> Maybe<&2, Enc>`,
  `Codec.decode_with_plan(k, t, plan, syms) -> Maybe<&2, List<G.Vec>>` (+ `encode_with_plan_auto`, `decode_with_plan_auto` in IO).
  A plan does not depend on T or the data; `None` when the plan does not fit K / the symbol count or T = 0.

## Tests
Python generators in `tools/` emit Bend fixture files from `tests/vectors/*.txt`. `bend tests/<x>_test.bend` exits non-zero on
failure; `scripts/test_all.sh` runs all of them.
