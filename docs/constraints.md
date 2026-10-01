# Constraint matrix rows and LT/PI encoding -- `src/types.bend`, `src/constraints.bend`

Test: `python3 tools/gen_constraints_test.py && bend tests/constraints_test.bend` (about 4 s, prints one PASS line per group
and `ALL TESTS PASSED`; exits 1 via `IO.die` on failure). `MAX_K=100 python3 tools/gen_constraints_test.py` limits the cases.
The generated test is ~230 KB (all golden symbols are embedded).

## What is tested (all against tests/vectors, which are independent of this code)
1. `fixed(sp, t) ++ source_rows(sp, ...)` for K'=10 and 26 equal `constraints.txt` row by row: every expected (col, coef) occurs exactly
   once and the term counts agree (so the term sets and GF(256) coefficients are identical; LDPC, HDPC and LT rows).
2. `encode_idx` on the golden intermediate symbols reproduces every golden encoded symbol (source ISI<K and repair, ESI -> ISI
   mapping, K<K' padding shift) for all 11 (K, T) groups with K <= 1000 (T = 5, 16, 32, 4); `encode` is compared with `encode_idx`.
3. Every row of `fixed() ++ source_rows(first K encoded symbols)` and of `received_rows(all encoded symbols with their ESIs)`
   evaluates to its rhs on the golden intermediates, i.e. A*C = D with zero rhs for the S+H rows and for the padding rows.

## Representation
* `Term{col, coef}`, `Row{cols: List<&2,Term>, rhs: Vec}` (types.bend). A row stores only non-zero entries in a list; HDPC rows are dense
  (about K'+S+1 terms each) but are still just lists, built in ascending column order. `Rcv{esi, sym}` is a received symbol.
* `rhs` of fixed rows is one shared zero symbol (`zero(t)`: ceil(t/4) packed words); `t` is the symbol size T in octets.

## Construction
* LDPC row r: `C[B+r]`, `C[W + r%P]`, `C[W + (r+1)%P]` and the first loop of RFC 5.3.3.3 *inverted*: writing i = q*S + k (so
  a = q+1, b_i = k), row r receives column i iff k = r - t*a (mod S) for t = 0,1,2 and i < B. A row therefore costs O(B/S) instead
  of scanning all B columns, with one `%` per block.
* HDPC row i of MT*GAMMA: entry(i,c) = sum_{j>=c} MT[i,j] alpha^(j-c) obeys e(c) = MT[i,c] + alpha*e(c+1), e(K'+S-1) = alpha^i,
  so each row is one backward scan (tail recursion, prepending, hence ascending output). MT[i,j] is 1 iff i = r1(j) or r2(j),
  with r1 = Rand[j+1,6,H], r2 = (r1 + Rand[j+1,7,H-1] + 1) % H; the (r1, r2) pairs are computed once (the list is shared by all H rows).
  The identity part adds `Term{K'+S+i, 1}`.
* `lt_terms`: literal Enc (5.3.5.3) using `R.tuple`; `% W` / `% P1` are conditional subtractions (a < W, a1 < P1); the
  `while b1 >= P` skips are bounded by P1-P+1 steps. Columns are distinct (W, P1 prime), term order is unspecified, all coef 1.
* All row lists are built by tail-recursive loops that prepend; the row bodies are independent redexes, so they evaluate in parallel
  (no divide-and-conquer needed, and no deep non-tail recursion).
* `index(inter)` builds an `ITree` (balanced; O(log L) lookup, out of range -> default) because list indexing is O(L).
  `encode(sp, inter, isi)` = `encode_idx(sp, index(inter), isi)`; reuse the tree when encoding many symbols.

## Performance (C backend, `bend file.bend` with an `IO` main)
K' = 56403: `fixed()` (1.08 M terms) about 2.3 s past the 1.3 s compile; `source_rows` about 1 s. A non-`IO` `main` runs in a much slower
evaluator (K'=1000 `fixed()` took 67 s that way vs well under a second with an IO main), so always benchmark with an IO main.

## Edge notes
* LDPC rows assume S prime (true for all Table 2 rows) so that the three hits b, b+a, b+2a of one i are distinct; if two coincided
  the RFC's XOR would cancel them while this code would list a duplicate column.
* `received_rows` returns the received rows in reverse input order, followed by the K'-K padding rows. Order is irrelevant to a solver.
