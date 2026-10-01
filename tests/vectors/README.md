# Golden vectors for the Bend RaptorQ implementation

Generated; do not hand-edit. All files: `#` lines are comments, everything else is whitespace-separated
decimal integers, one record per line. Octets are 0..255. Total size ~290 KB.

## Regenerate
```
cd tools/vectors && ~/.cargo/bin/cargo run --release      # writes ../../tests/vectors/{params,source,encoded,intermediate,decode}.txt
cd ../.. && python3 tools/ref_constraints.py              # writes constraints.txt, tuples.txt AND cross-checks the crate's output
```
Output is deterministic (fixed seeds, no clocks). `tools/vectors` depends on `tools/vectors/vendor/raptorq`,
a COPY of `ref/raptorq-rs` (cberner/raptorq 2.0.1) with python.rs and dev-deps removed plus one added accessor
`SourceBlockEncoder::intermediate_symbols_shim()` and re-exports of the Table 2 accessors (see vendor/README.md).
No algorithm was changed; `ref/` is untouched.

## Cases
(K,T) with one source block (Z=1, N=1, alignment 1):
K in {1,2,10,26} x T in {16,32,5}; K in {50,100} x T in {16,5}; K in {500,1000} x T=4. T=5 is the odd size.
Repair symbols per case: R = max(20, K/4+3) (ESIs K..K+R-1).
ESI numbering is the RFC external one: source ESI 0..K-1, repair ESI K+i (i>=0). The repair symbol with ESI
K+i is computed from internal symbol id ISI = K'+i (RFC 5.3.1, 5.3.4, 5.3.5.3): ESIs K..K'-1 are the padding
symbols (zero data, never transmitted).

## Files
- `params.txt` (RFC 5.6 Table 2, 5.3.3.3): `K Kprime J S H W L P P1`. L=K'+S+H, P=L-W, P1=smallest prime >= P.
- `source.txt` (RFC 4.4.1, 5.3.1): `K T i b0..b{T-1}`, source symbol i. Regenerate in Bend: x = K*65536+T (u32);
  for each of K*T bytes: `x = (x*1664525 + 1013904223) mod 2^32; byte = x >> 24`; symbol i = bytes [iT,(i+1)T).
- `encoded.txt` (RFC 5.3.4, 5.3.5.3): `K T esi b0..b{T-1}` for esi 0..K+R-1. esi<K equals source.txt (systematic,
  asserted by generator); esi>=K are repair symbols.
- `intermediate.txt` (RFC 5.3.3.4, 5.4.2): `K T idx b0..b{T-1}`, C[idx], idx 0..L-1 (L from params.txt). The D vector
  fed to the solver is S+H zero symbols, then the K source symbols, then K'-K zero padding symbols (5.3.3.4.2).
- `decode.txt` (RFC 5.4): `id K T nrecv ok nsrc kindcode e_0 .. e_{nrecv-1}   # kind`. Received ESIs sorted,
  data from encoded.txt. `ok=1`: decoding must succeed and return the K*T source bytes of source.txt; `ok=0`: reference decoder
  fails (singular) so must yours (in the current set every case has ok=1; none of the 90 failed). Kinds: 0 randloss
  (max(1,K/4) random source symbols lost, replaced by random repair so nrecv = K, K+1, K+2), 1 nodrop (all K source),
  2 allrepair (K<=18: no source symbols, K+1 and K+2 repair symbols only). `nsrc` = number of received ESIs < K.
  Loss patterns come from a second LCG; Bend need not regenerate them, just read the ESI lists.
- `constraints.txt` (RFC 5.3.3.3, Fig. 6 / 5.3.3.4.2) **independently derived** by tools/ref_constraints.py, K'=10 and 26:
  `Kp row kind n col val ...` non-zero entries of matrix A row by row: kind 0 LDPC rows (0..S-1), 1 HDPC rows
  (S..S+H-1, GF(256) values), 2 LT rows for ISI X = row-S-H, X in 0..K'-1. (Permanent-inactive / padding rows
  are exactly rows with X>=K; for K<K' the right-hand side of those rows is zero.) A*C = (0^(S+H), D_src, 0 padding).
- `tuples.txt` (RFC 5.3.5.4) independently derived: `Kp X d a b d1 a1 b1` for X = 0..K'+19, K' in {10,26}.

## RFC 6330 conformance of the crate
- The generator asserts systematic symbols == source data, and that the decoder returns the source for every ok=1 case.
- `tools/ref_constraints.py` re-implements Rand/Deg/Tuple/Enc, GF(256), LDPC and HDPC relations from `ref/rfc6330.txt`
  (V tables and Table 2 parsed from the RFC text; no code or tables from the crate) and verifies, for K=1,2,10 (K'=10),
  26 (K'=26) and all T: A*C equals (zeros, source, zero padding) using the crate's intermediate symbols, and
  every repair symbol equals Enc over C with ISI=K'+i. All pass, so intermediate + repair symbols, padding behaviour
  (RFC 5.3.1) and ESI->ISI mapping are RFC-conformant for these K'. Larger K' are the crate's (RFC-tested) output only.
