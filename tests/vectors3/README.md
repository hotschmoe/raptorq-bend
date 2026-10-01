# Golden vectors for multi-block objects (RFC 6330 4.3, 4.4)

Generated; do not hand-edit. `#` lines are comments, everything else is whitespace-separated decimal integers, one record per line.
Total about 160 KB. Consumed by `tools/gen_blocks_test.py` (-> `tests/blocks_fixtures.bend`) and `tests/blocks_test.bend`; see docs/multiblock.md.

## Regenerate
```
cd tools/vectors3 && ~/.cargo/bin/cargo run --release        # writes ../../tests/vectors3/{oti,packets,decode,partition,kmax,params}.txt
cd ../.. && python3 tools/gen_blocks_test.py                  # writes tests/blocks_fixtures.bend
```
Deterministic (fixed LCG seeds, no clocks). `tools/vectors3` depends on the vendored crate `tools/vectors/vendor/raptorq` (cberner/raptorq 2.0.1;
the only change for this tool is that `ObjectTransmissionInformation::generate_encoding_parameters` is `pub`). The reference decoder
(`raptorq::Decoder`) is run on every decode scenario and must return the original object, else the generator asserts (and, for a scenario,
adds received symbols until it does).

## Files
- `oti.txt`: `id seed F T Z N Al  Kt KL KS ZL ZS  o0..o11`: object id, data seed, the five OTI fields, `Kt = ceil(F/T)`, `(KL, KS, ZL, ZS) = partition(Kt, Z)`,
  and the 12 octets of `ObjectTransmissionInformation::serialize()` (RFC 3.3.2 / 3.3.3).
  Object bytes: x = seed; for each of the F bytes: `x = (x*1664525 + 1013904223) mod 2^32; byte = x >> 24` (same LCG as tests/vectors).
  11 objects: Z = 1 .. 11 with ZL > 0 and ZS > 0 blocks, ZL = 0 (all blocks equal), tiny blocks (K < 10, so K' = 10 padding in every block), T = 4 .. 32 including the odd
  T = 5, Al = 1, 2, 4, 8, sub-blocks N = 1 .. 5 including N that does not divide T/Al (sub-symbols of different sizes, e.g. 12, 12, 8 octets).
- `packets.txt`: `id sbn esi b0..b{T-1}`: every source packet (ESI 0..K-1, with sub-blocks the permuted symbols) and K/3 + 12 repair packets (ESI K..) of every
  source block, block by block, as `Encoder::new(data, config).get_block_encoders()[sbn].source_packets()/repair_packets()` returns them
  (K = the block's number of source symbols, ESI numbering is the external RFC one).
- `decode.txt`: `id kind nrecv  sbn esi sbn esi ...`: the received (sbn, esi) pairs in arrival order; the data are the packets of `packets.txt`. kind 0: the same loss pattern in
  every block (1 of 3 source symbols lost, repair symbols K, K+1, .. added); kind 1: a different pattern per block (every 3rd/4th/5th source symbol lost, repair
  symbols starting at K + (sbn mod 3), K + (sbn mod 2) extra symbols); kind 2: pattern of kind 0, arrival order shuffled across all blocks. Every scenario recovers
  the object with the reference decoder.
- `partition.txt`: `I J IL IS JL JS` as `raptorq::partition(I, J)` (RFC 4.4.1.2 Partition[I, J]), I in 1 .. 56404.
- `kmax.txt`: `x kmax`: the largest K' of RFC Table 2 with K' <= x (0 below 10), derived with the crate's `extended_source_block_symbols`. This is the K_L(n) of RFC 4.3 once
  `x = WS / (Al * ceil(T / (Al * n)))` is known (K'max = 56403).
- `params.txt`: `F P' Al SS WS  T Z N Al'` from `ObjectTransmissionInformation::generate_encoding_parameters(F, P', WS)` (RFC 4.3, `Al`/`SS` are what the crate derives from P': 8/8 for
  P' >= 64, else 1/1). `Z = 0` marks the 188 combinations whose true Z exceeds 255: the crate truncates Z to u8 there, so the line only says that Bend must reject the parameters.
