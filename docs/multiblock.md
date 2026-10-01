# Multi-block objects (RFC 6330 sections 3.3, 4.3, 4.4) -- `src/blocks.bend`, `src/blocks_demo.bend`

A source object of F octets is cut into Z source blocks (RFC 4.4.1.2), every block into N sub-blocks, and every source block is encoded and
decoded independently with the single-block codec of `src/raptorq.bend` (`docs/codec.md`). Blocks are independent, so this is the first place
where the repo has a genuinely parallel workload; most of this document is about how that is arranged for Bend's runtime and what it measured.

`import ./src/blocks.bend as B`, calls look like `B.Blocks.params(..)`. Pure Bend, no foreign code.

## What it implements

| RFC | `Blocks.*` |
|---|---|
| 4.4.1.2 `Partition[I,J] = (IL, IS, JL, JS)` | `partition(i, j) -> Part{il, ish, jl, js}` |
| 4.4.1.2 `(KL, KS, ZL, ZS) = Partition[Kt, Z]`, Kt = ceil(F/T) | `layout(oti) -> Lay{kt, kl, ks, zl, zs}`, `block_k(lay, sbn)`, `num_blocks(lay)` |
| 4.3 `K_L(n)` = largest Table 2 K' <= WS / (Al * ceil(T / (Al * n))) | `kl(ws, al, t, n)` (reads Table 2 through `Rfc.params`, scanning down from the bound; K'max = 56403) |
| 4.3 derivation of T, Z, N from F, P', Al, WS, SS | `params(f, p, al, ws, ss) -> Maybe<Oti>` |
| 3.3.2 / 3.3.3 OTI (F, T, Z, N, Al), 12 octets | `Oti{f, t, z, n, al}`, `oti(f, t, z, n, al)` (validated), `valid`, `oti_bytes(oti)`, `oti_parse(bytes)` |
| 3.2 payload id (SBN 8 bit, ESI 24 bit) | `payload_id(sbn, esi) -> U32`, packets are `Pkt{sbn, esi, sym}` |
| 4.4.1.2 object -> blocks -> sub-blocks -> symbols | `split_object(oti, bytes) -> List<List<Sym>>` (K source symbols per block, last symbol zero padded, sub-block interleave for N > 1), `join_object` is its inverse |
| 4.4.2 encoding packets | `encode_object(w, oti, bytes)`, `encode_syms(w, oti, src)` -> `Maybe<Obj>`; `symbol(obj, sbn, esi) -> Maybe<Sym>`; `repair(w, obj, n)`; `encode_repair(w, oti, n, src)` (fused, see below) |
| 4.4.3 / 5.4 recovery | `decode_object(w, oti, pkts) -> Maybe<bytes>`, `decode_syms(w, oti, pkts) -> Maybe<List<List<Sym>>>` |

`w` is the number of workers of the block tree (pass `IO.thread_count()`; 1 = sequential). `Obj{oti, lay, encs}` holds one `Codec.Enc` per block
(the intermediate symbols), so `symbol` is random access. `Pkt` replaces the `(sbn, esi, Sym)` triple. Packets of unknown blocks are ignored, duplicates
and arbitrary order are fine, a block with fewer than K symbols (or a rank-deficient set) makes the object `None`.

Limits: F is a `U32` (the RFC allows 40 bit: objects up to 4 GiB - 1), Z <= 255 (OTI field is 8 bit), T <= 65535, Al <= 255, N <= T/Al, K <= 56403 per block
(`ceil(Kt/Z) <= 56403`, checked by `valid`). The 12 octets of a 40-bit F whose top octet is non-zero are rejected by `oti_parse`.
Sub-blocks (N > 1) are implemented as the RFC describes: they only permute the octets of the source block (symbol m = concatenation of the m-th
sub-symbol of every sub-block); the code itself is applied to whole T-octet symbols, exactly as the Rust crate does it.

## Parallel design

Rules this design follows (`docs/profile.md` sections 6-7, `docs/scaling.md` rules 1-6):

1. **One parallel region per phase, outermost, fork tree.** Forks reached from sequential code cost ~0.3 ms and forks inside a running task are free, so
   every parallel function (`encode_*`, `repair`, `decode_*`) is ONE divide and conquer over the block range `[0, Z)` for `w` workers: a node with `w`
   workers and `n` blocks gives its left child `floor(w/2)` workers and `n*floor(w/2)/w` blocks (proportional split, so `w = 12, n = 64` gives leaves of
   5 and 6 blocks, not 4 + 4 + ... + 16 tasks on 12 threads), forks `a b = range(left) range(right)` and appends the result lists. `levels(w)` is the
   recursion fuel. The only other fork reached from sequential code is the pair of plan computations that precede the tree (below).
2. **Leaves are tail-recursive loops.** A leaf (one worker, or a single block) runs its blocks one after the other in `leaf(..)`, a tail loop whose body is
   `blk(cx, sbn, inputs)`. The fork-free recursion sits in its own def, never in the def that contains the fork (`docs/scaling.md` rule 4: a def that merely
   contains a parallel `let` makes all its non-tail calls heap-allocate continuations at `--threads > 1`). The per-block code (`Solver.apply`, `Flat.*`) is
   tail loops over arrays: measured, one leaf runs at the same speed at `--threads 1`, 2 and 8 (275 / 275 / 275 ms for 8 blocks).
3. **No sharing of `Data` between leaves where it can be avoided.** The source symbols are dropped down the tree (`List.drop` of the left part), the received
   packets are *routed* down the tree: every node partitions its packet list by `sbn < mid` (order-preserving), so a leaf only ever sees its own blocks'
   packets and no list is scanned once per block (a 64-block, 56000-packet decode partitions in 6 passes, the first sequential and the rest inside tasks).
4. **Plans are shared, per K and (decoder) per ESI sequence.** The plan (symbol-independent half of the solve, `Codec.plan_for`) depends only on K and which
   ESIs arrive in which order. All ZL blocks have K_L, all ZS blocks K_S, so the encoder computes at most two plans (`Codec.encoder_plan`, concurrently),
   once, before the tree. The decoder takes the packets of the first block of each class, computes `plan_for(K, esis)` for those two (concurrently), and every
   block whose ESI sequence is *identical* to its class representative's reuses that plan; a block with a different loss pattern builds its own inside its
   leaf. `tests/blocks_test.bend` checks both (the "same losses in every block" and "different per block" scenarios).
5. **Fused encode + repair on the flat arena** (`encode_repair`): `Codec.encode_with_plan` returns an `Enc` (trees of boxed words for the L intermediate
   symbols) and `Codec.symbols` copies them back into a flat array. `Blocks.encode_repair` instead does what `Codec.decode_with_plan` already does:
   `Solver.apply_arena` and `Flat.encode_arena` inside the leaf, no tree conversion of the intermediate symbols and no `Enc`/`Obj`. It reaches into two
   internals of `raptorq.bend` (`wp.rhs`, `wp.ok`), see "Requests". `encode_syms` + `repair` (the `Obj` path, random access to any symbol later) is
   1.8x more work for the same repair symbols (1038 ms vs 585 ms for 16 blocks of K = 1000, T = 1024, one thread).

The decoder returns the K source symbols re-encoded from the intermediate symbols (like `Codec.decode_with_plan`); received source symbols are not copied through.

## Tests

* `tools/vectors3/` (cargo project on the vendored crate, `cd tools/vectors3 && cargo run --release`) writes `tests/vectors3/*.txt` (formats and regeneration
  in `tests/vectors3/README.md`): `partition` (118 `(I,J)` cases), `kmax` (40), `params` (720 `generate_encoding_parameters` cases: 532 derived (T, Z, N), 188 where
  the true Z exceeds 255 and the crate silently truncates it to u8, which Bend must reject), 11 objects with the OTI bytes the crate serializes, every source and
  repair packet of every block (1681 packets) and 33 decode scenarios with losses spread over the blocks (the crate's own `Decoder` recovers each one).
* `python3 tools/gen_blocks_test.py` turns them into `tests/blocks_fixtures.bend`; `bend tests/blocks_test.bend` (about 10-20 s): partition vectors and the
  arithmetic laws on a 70 x 70 grid, `kmax`, all 720 parameter cases, OTI layout / serialization / parsing / rejections, then for each of the 11 objects (Z = 1 .. 11,
  ZL and ZS blocks, K = 5 .. 63 so K' padding happens, T = 4 .. 32 incl. odd T = 5, Al = 1 .. 8, N = 1 .. 5): `split_object` equals the crate's source packets, every
  source and repair packet equals `Blocks.symbol` of `encode_object`, `Blocks.repair` and the fused `encode_repair` equal the crate's repair packets, and `decode_object`
  recovers the object from every scenario (and returns `None` when a whole block is missing), each for 1, 3 and 5 workers (the tree shapes differ, the results do not).
  Prints one line per group and `ALL PASS`.
* `scripts/test_all.sh` picks the suite up (it globs `tests/*_test.bend`).

RESULTS_PLACEHOLDER
