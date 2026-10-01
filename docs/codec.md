# End-to-end codec (RFC 6330 5.3 / 5.4) -- `src/raptorq.bend`, `src/raptorq_demo.bend`

`import ../src/raptorq.bend as Q`, then `Q.Codec.split(..)` etc. Single source block only (RFC 4.4.1.2: K = ceil(F/T),
1 <= K <= 56403); multi-block partitioning (Z > 1, 4.4.1.2 / 4.3 sub-blocking, OTI/payload-id framing) is out of scope.
`Sym` = `G.Vec` (packed words, see gf256.md); `T` is the true symbol size in octets.

## API
| def | meaning |
|---|---|
| `Codec.k_of(len, t) -> U32` | K = max(1, ceil(len/t)) |
| `Codec.split(data: List<&2,U32>, t) -> List<&2,Sym>` | bytes (U32 < 256 each) -> K source symbols of T octets, last one zero padded (K = length of the result; also T not a multiple of 4: octets are zero padded inside the last word) |
| `Codec.join(syms, t, len) -> List<&2,U32>` | first `len` octets of the concatenated symbols (drops the padding); `Codec.sym_bytes(sym, t)` for one symbol |
| `Codec.encoder(k, t, source: List<&2,Sym>) -> Maybe<&2,Enc>` | solver runs once (5.3.3.4); `Enc{k,t,sp,tr}` holds the parameters and an `ITree` of the L intermediate symbols. `None` if K=0, T=0, K>56403, or `source` does not have exactly K symbols |
| `Codec.symbol(enc, esi) -> Sym` / `Codec.repair` | encoding symbol for the external ESI: `ESI < K` -> ISI = ESI (the source symbol, systematic), `ESI >= K` -> ISI = ESI + K' - K (repair). `repair` is an alias. O(d log L) per symbol, any ESI order, any number of times |
| `Codec.symbols(enc, esi0, n) -> List<&2,Sym>` | n consecutive encoding symbols |
| `Codec.decode(k, t, received: List<&2,Y.Rcv>) -> Maybe<&2,List<&2,Sym>>` | `Rcv{esi, sym}` in any order. `fixed ++ received_rows` -> `Solver.solve_p(L, P, ..)` -> source symbols ESI 0..K-1. `None` if fewer than K symbols, invalid K/T, or rank deficient (RFC 5.4.2 failure) |

Design notes
* Flat symbol path (`src/flat.bend`, docs/profile.md R1): `Codec.symbols` (for more than about L/40 symbols; fewer take the per-symbol
  tree path) and `Codec.decode` / `decode_with_plan` (the K source-symbol re-encodings) copy the L intermediate symbols ONCE into one
  `Array<U32>` (symbol c at slots c*W..), compute each encoding symbol as a tail-recursive loop that XORs the LT/PI columns' slices
  into a scratch slice (first term copies), and read the scratch slice out as a `Vec` (same shape as `Vec.from_list`). `Codec.symbol`
  (one ESI) keeps the tree path. `Enc` stays `Data` (an `Array` is linear, so it cannot live in it), hence the copy per call.
* `decode` re-encodes ALL K source symbols from the intermediate symbols (the received source symbols are not copied
  through). For consistent input this is identical; with corrupted input the result is the code word nearest the solver's
  choice, not the received bytes (the solver does not detect inconsistent overdetermined systems, see solver.md).
* Everything that loops over >= 32k elements is tail recursive (Base `List.length/append` are not and overflow the stack:
  the module has `len_*`, `append_rows`). Matrix building is linear in K'; the solver is the limit (K' ~ 4000 is ~10 s).
* `match` cannot scrutinize a call result, so multi-step byte code is written as state structs (`Wk`, `Ss`, `Pb`) threaded
  through tail-recursive loops.

## Tests
* `python3 tools/gen_codec_test.py` (regenerates `tests/codec_fixtures.bend`, 139 KB: packed 4-octet words, chunked literals,
  from `tests/vectors` and `tests/vectors2`; `MAX_K=100` limits the cases).
* `bend tests/codec_test.bend` (about 1 min interpreted incl. ~6 s compile; `bend tests/codec_test.bend -o ct && ./ct`: 13 s
  after a ~13-30 s build). Prints one line per case, `ALL PASS`, exits 1 on failure:
  1. encoder: all ESIs 0..K+R-1 equal `encoded.txt` for all 18 (K,T) cases incl. K=500/1000 T=4 and T=5, and the 5 cases of vectors2;
  2. decoder: all 90 cases of `tests/vectors/decode.txt` and all 100 of `tests/vectors2/decode.txt` (15 of them are cases on
     which the Rust reference decoder FAILS: Bend must return `None`, and the dense oracle `Solver.solve_dense` must also see
     a rank-deficient matrix);
  3. `Codec.encoder/decode` edge cases (K=0, K=56404, T=0, wrong source count, too few symbols), split/join round trips
     (lengths 0..4096, T = 1,3,4,5,7,16), known byte->word values;
  4. roundtrip properties on 19 (K,T) groups (K=1..100, T=4,5,16; 1056 generated loss patterns: pure-repair and mixed pools,
     K+0..K+3 received, selection sampling from an LCG, last symbol partially filled): `Some` => `join` equals the original
     bytes; `None` => the dense oracle also reports rank deficiency (a `None` with a full-rank matrix counts as BAD).
     Note the random patterns produced no rank-deficient case in this run (failure probability at exactly K received is
     ~0.1-1 %); the `None` branch is exercised by the vectors2 failure cases.
* `tools/vectors2/` (separate cargo project; `cd tools/vectors2 && cargo run --release`, writes `tests/vectors2/{encoded,decode}.txt`,
  same line formats as `tests/vectors`, extra kind codes 3..7 in its header): K in {10,26,50,100} (+ (10,5)) with exactly K
  received symbols that are all/mostly repair, K+1 pure repair, plus up to 3 searched patterns per case where the reference decoder
  reports failure. All vectors2 decodes recovered by Bend match the reference (ok=1) and all ok=0 are `None` in Bend.

## Demo / benchmark
`bend src/raptorq_demo.bend` encodes a text (T=16), drops every 4th source symbol, adds repair symbols, decodes, prints the text.
`bend src/raptorq_demo.bend -o demo && ./demo -- bench K M [T]` (M=0 encoder + 20 repair symbols, M=1 additionally decodes
after losing 1/4 of the source symbols (K/4+1 repair symbols substituted); decode time = M=1 minus M=0).
Native binary, IO main, 12-core aarch64, wall clock of the whole process, T=16 unless noted:

| K | encoder (solve + 20 repair) | encode + decode | decode alone (diff) |
|---|---|---|---|
| 10   | 0.015 s | 0.014 s | ~0 |
| 100  | 0.045 s | 0.061 s | 0.02 s |
| 1000 | 0.96 s  | 1.78 s  | 0.8 s |
| 4000 | 10.0 s  | 20.5 s  | 10.5 s |
| 1000, T=1024 | 1.9 s | 7.3 s | 5.4 s |

## Requests / notes for other modules
* None required. Observations: decoding K=1000, T=1024 is ~3x the encoder: the decode system has fewer sparse LT rows
  and so more pivoting work on the symbol side; a solver that applies row operations on symbols lazily (record the
  operation sequence on the matrix, replay on symbols once - RFC 5.4.2.2 "operation vector") would help T >> 16.
* `Solver.solve_p` returns `Some` for rank-complete systems even if extra rows are inconsistent; the codec inherits that.
