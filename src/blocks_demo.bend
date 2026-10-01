# Multi-block object demo and benchmark for src/blocks.bend (docs/multiblock.md).
#   bend src/blocks_demo.bend                          encode a text as a multi-block object with sub-blocks (RFC 4.3 parameters), lose
#                                                      a quarter of the source packets of every block, decode it back
#   bend src/blocks_demo.bend -o build/blocks_demo
#   ./build/blocks_demo [--threads W] -- bench Z K T [pat [W [fused]]]
#        Z source blocks of K symbols of T octets (T a multiple of 4; the object is Z*K*T octets, N = 1, Al = 4):
#        phases (wall ms each): gen (source symbols, parallel), enc (plans + all blocks), rep (K*7/8 repair symbols per block),
#        dec (decode from K symbols per block, 7/8 of them repair), then an untimed verification.  pat = 0: every block receives
#        the same ESIs (one shared plan per K), pat = 1: a different ESI set per block (every block builds its own plan);
#        W = leaf tasks of the block tree (default Z), fused = 1: encode_repair instead of encode_syms + repair.
# Prints one machine-readable line:  BLOCKS Z=.. K=.. T=.. w=.. pat=.. gen_ms=.. enc_ms=.. rep_ms=.. dec_ms=.. ok=1
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./raptorq.bend as Q
import ./blocks.bend as B

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def lst_eq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(U32.is_eq(x, y), lst_eq(xs, ys))
    case _ _:
      False{}

def syms_eq(a: List<&2, G.Vec>, b: List<&2, G.Vec>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(lst_eq(G.Vec.to_list(x, Nil{}), G.Vec.to_list(y, Nil{})), syms_eq(xs, ys))
    case _ _:
      False{}

def blocks_eq(a: List<&2, List<&2, G.Vec>>, b: List<&2, List<&2, G.Vec>>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(syms_eq(x, y), blocks_eq(xs, ys))
    case _ _:
      False{}

def b2u(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0

# ---------------------------------------------------------------------------
# source data: symbol i of block sbn = T/4 LCG words seeded from (sbn, i)
# ---------------------------------------------------------------------------

def words.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      words.go(p, lcg(x), lcg(x) <> acc)

def gen_sym(+wd: U32, +sbn: U32, +i: U32) -> G.Vec:
  G.Vec.from_list(words.go(U32.to_nat(wd), (((sbn * 100003 + i : U32) * 2654435761 : U32) + 12345 : U32), Nil{}))

def gen_blk(n: Nat, +i: U32, +sbn: U32, +wd: U32, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      List.reverse(&2, G.Vec, acc)
    case 1n+p:
      gen_blk(p, (i + 1 : U32), sbn, wd, gen_sym(wd, sbn, i) <> acc)

def gen_leaf(n: Nat, +sbn: U32, +k: U32, +wd: U32, acc: List<&2, List<&2, G.Vec>>) -> List<&2, List<&2, G.Vec>>:
  match n:
    case 0n:
      List.reverse(&2, List<&2, G.Vec>, acc)
    case 1n+p:
      gen_leaf(p, (sbn + 1 : U32), k, wd, gen_blk(U32.to_nat(k), 0, sbn, wd, Nil{}) <> acc)

def gen_range(+d: Nat, lf: Bool, +w: U32, +n: U32, +sbn: U32, +k: U32, +wd: U32) -> List<&2, List<&2, G.Vec>>:
  match d:
    case 0n:
      gen_leaf(U32.to_nat(n), sbn, k, wd, Nil{})
    case 1n+q:
      match lf:
        case True{}:
          gen_leaf(U32.to_nat(n), sbn, k, wd, Nil{})
        case False{}:
          +wl = (w / 2 : U32)
          +nl = B.n_left(w, n)
          +wr = (w - wl : U32)
          +nr = (n - nl : U32)
          a b = gen_range(q, B.is_leaf(wl, nl), wl, nl, sbn, k, wd) gen_range(q, B.is_leaf(wr, nr), wr, nr, (sbn + nl : U32), k, wd)
          B.Blocks.app(List<&2, G.Vec>, a, b)

# the source symbols of Z blocks of K symbols of T octets
def gen_object(+w: U32, +z: U32, +k: U32, +t: U32) -> List<&2, List<&2, G.Vec>>:
  gen_range(B.levels(w), B.is_leaf(w, z), w, z, 0, k, (t / 4 : U32))

# ---------------------------------------------------------------------------
# received packets: K per block, 7/8 of them repair (ESI K, K+1, ..), the rest source symbols i = r (mod 8);  pat = 1 gives every
# block its own r = sbn mod 8 and its own first repair ESI (K + sbn mod 4)
# ---------------------------------------------------------------------------

def src_pick(hit: Bool, p: B.Pkt, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match hit:
    case True{}:
      p <> acc
    case False{}:
      acc

def src_pkts(s: List<&2, G.Vec>, +i: U32, +r: U32, +sbn: U32, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match s:
    case Nil{}:
      acc
    case Con{v, rest}:
      src_pkts(rest, (i + 1 : U32), r, sbn, src_pick(U32.is_eq((i .&. 7 : U32), r), B.Pkt{sbn, i, v}, acc))

def rep_pkts(n: Nat, rs: List<&2, G.Vec>, +esi: U32, +sbn: U32, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match n:
    case 0n:
      acc
    case 1n+p:
      match rs:
        case Nil{}:
          acc
        case Con{v, rest}:
          rep_pkts(p, rest, (esi + 1 : U32), sbn, B.Pkt{sbn, esi, v} <> acc)

# K - ceil(K/8) repair symbols
def n_rep(+k: U32) -> U32:
  (k - (k + 7 : U32) / 8 : U32)

def blk_pkts(+pat: U32, +sbn: U32, +k: U32, s: List<&2, G.Vec>, rs: List<&2, G.Vec>, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  +r = Bool.pick(U32, U32.is_eq(pat, 0), 0, (sbn .&. 7 : U32))
  +off = Bool.pick(U32, U32.is_eq(pat, 0), 0, (sbn .&. 3 : U32))
  rep_pkts(U32.to_nat(n_rep(k)), List.drop(&2, G.Vec, rs, U32.to_nat(off)), (k + off : U32), sbn, src_pkts(s, 0, r, sbn, acc))

def all_pkts(ss: List<&2, List<&2, G.Vec>>, rr: List<&2, List<&2, G.Vec>>, +pat: U32, +sbn: U32, +k: U32, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match ss rr:
    case s <> st r <> rt:
      all_pkts(st, rt, pat, (sbn + 1 : U32), k, blk_pkts(pat, sbn, k, s, r, acc))
    case _ _:
      acc

# ---------------------------------------------------------------------------
# benchmark: gen -> enc -> rep -> dec -> verify, one stage def per phase (a `match` needs a parameter, and printing a value that
# depends on the phase's result forces it before the next timestamp is read)
# ---------------------------------------------------------------------------

def pk_len(xs: List<&2, B.Pkt>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, tl}:
      pk_len(tl, (acc + 1 : U32))

def some_enc(m: Maybe<&2, B.Obj>) -> U32:
  match m:
    case None{}:
      0
    case Some{o}:
      1

def some_dec(m: Maybe<&2, List<&2, List<&2, G.Vec>>>) -> U32:
  match m:
    case None{}:
      0
    case Some{o}:
      1

def fold_words(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, tl}:
      fold_words(tl, (acc * 31 + h : U32))

def fold_syms(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{v, tl}:
      fold_syms(tl, (acc * 31 + fold_words(G.Vec.to_list(v, Nil{}), 0) : U32))

def fold_blocks(xs: List<&2, List<&2, G.Vec>>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{b, tl}:
      fold_blocks(tl, fold_syms(b, acc))

# checksum of the last symbol of the last block (forces the repair work of that block, not necessarily the others)
def last_sym(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{v, tl}:
      last_sym(tl, fold_words(G.Vec.to_list(v, Nil{}), 0))

def last_chk(xs: List<&2, List<&2, G.Vec>>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{b, tl}:
      last_chk(tl, last_sym(b, 0))

# the benchmark's parameters and the phase times so far (ms, newest first: dec, rep, enc, gen)
type Bx is Data:
  Bx{oti: B.Oti, z: U32, k: U32, w: U32, pat: U32, tm: List<&2, U32>}

def Bx.push(bx: Bx, +v: Nat) -> Bx:
  match bx:
    case Bx{oti, z, k, w, pat, tm}:
      Bx{oti, z, k, w, pat, U32.from_nat(v) <> tm}

def Bx.k(bx: Bx) -> U32:
  match bx:
    case Bx{oti, z, k, w, pat, tm}:
      k

def Bx.w(bx: Bx) -> U32:
  match bx:
    case Bx{oti, z, k, w, pat, tm}:
      w

def Bx.oti(bx: Bx) -> B.Oti:
  match bx:
    case Bx{oti, z, k, w, pat, tm}:
      oti

def report(bx: Bx, +ver: Nat, +ok: U32) -> IO(Unit):
  match bx:
    case Bx{oti, +z, +k, +w, +pat, tm}:
      match tm:
        case dec <> rep <> enc <> gen <> Nil{}:
          IO.print("BLOCKS Z=" ++ U32.show(z) ++ " K=" ++ U32.show(k) ++ " T=" ++ U32.show(B.Blocks.oti_t(oti)) ++ " w=" ++ U32.show(w) ++ " pat=" ++ U32.show(pat) ++ " gen_ms=" ++ U32.show(gen) ++ " enc_ms=" ++ U32.show(enc) ++ " rep_ms=" ++ U32.show(rep) ++ " dec_ms=" ++ U32.show(dec) ++ " verify_ms=" ++ Nat.show(ver) ++ " ok=" ++ U32.show(ok))
        case _:
          IO.die(Unit, 1, "bad timing list")

# stage 5: verify (not part of the table's phases)
def st_ver(res: Maybe<&2, List<&2, List<&2, G.Vec>>>, +src: List<&2, List<&2, G.Vec>>, bx: Bx) -> IO(Unit):
  match res:
    case None{}:
      IO.die(Unit, 1, "FAIL: decode returned None")
    case Some{out}:
      do IO<Unit>:
        +t5 : Nat <- IO.now()
        +ok : U32 <- IO.pure(U32, b2u(blocks_eq(out, src)))
        IO.print("verified " ++ U32.show(ok))
        +t6 : Nat <- IO.now()
        report(bx, (t6 - t5 : Nat), ok)

# stage 4: decode the received packets
def st_dec(bx: Bx, +src: List<&2, List<&2, G.Vec>>, +rr: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match bx:
    case Bx{+oti, z, +k, +w, +pat, tm}:
      +pk = all_pkts(src, rr, pat, 0, k, Nil{})
      do IO<Unit>:
        +n : U32 <- IO.pure(U32, pk_len(pk, 0))
        IO.print("packets " ++ U32.show(n))
        +t3 : Nat <- IO.now()
        +res : Maybe<&2, List<&2, List<&2, G.Vec>>> <- IO.pure(Maybe<&2, List<&2, List<&2, G.Vec>>>, B.Blocks.decode_syms(w, oti, pk))
        IO.print("decoded " ++ U32.show(some_dec(res)))
        +t4 : Nat <- IO.now()
        st_ver(res, src, Bx.push(Bx{oti, z, k, w, pat, tm}, (t4 - t3 : Nat)))

# stage 3: repair symbols of every block of the encoded object
def st_rep(m: Maybe<&2, B.Obj>, +bx: Bx, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encode_syms returned None")
    case Some{obj}:
      +w = Bx.w(bx)
      +n = (n_rep(Bx.k(bx)) + 4 : U32)
      do IO<Unit>:
        +t2 : Nat <- IO.now()
        +rr : List<&2, List<&2, G.Vec>> <- IO.pure(List<&2, List<&2, G.Vec>>, B.Blocks.repair(w, obj, n))
        IO.print("repair checksum " ++ U32.show(last_chk(rr, 0)))
        +t3 : Nat <- IO.now()
        st_dec(Bx.push(bx, (t3 - t2 : Nat)), src, rr)

def st_fin(m: Maybe<&2, List<&2, List<&2, G.Vec>>>, bx: Bx, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encode_repair returned None")
    case Some{rr}:
      st_dec(Bx.push(bx, 0n), src, rr)

# stage 2 (fused): encode + repair symbols in one parallel region (arena path, no Obj)
def st_fused(+bx: Bx, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    +m : Maybe<&2, List<&2, List<&2, G.Vec>>> <- IO.pure(Maybe<&2, List<&2, List<&2, G.Vec>>>, B.Blocks.encode_repair(Bx.w(bx), Bx.oti(bx), (n_rep(Bx.k(bx)) + 4 : U32), src))
    IO.print("encoded+repaired " ++ U32.show(some_dec(m)))
    +t2 : Nat <- IO.now()
    st_fin(m, Bx.push(bx, (t2 - t1 : Nat)), src)

# stage 2: encode all blocks
def st_enc(+bx: Bx, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    +m : Maybe<&2, B.Obj> <- IO.pure(Maybe<&2, B.Obj>, B.Blocks.encode_syms(Bx.w(bx), Bx.oti(bx), src))
    IO.print("encoded " ++ U32.show(some_enc(m)))
    +t2 : Nat <- IO.now()
    st_rep(m, Bx.push(bx, (t2 - t1 : Nat)), src)

def st_pick(fused: Bool, bx: Bx, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match fused:
    case True{}:
      st_fused(bx, src)
    case False{}:
      st_enc(bx, src)

# stage 1: generate the source data
def bench(+z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +fused: U32) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +src : List<&2, List<&2, G.Vec>> <- IO.pure(List<&2, List<&2, G.Vec>>, gen_object(w, z, k, t))
    IO.print("source checksum " ++ U32.show(fold_blocks(src, 0)))
    +t1 : Nat <- IO.now()
    st_pick(U32.is_eq(fused, 1), Bx.push(Bx{B.Oti{(z * k * t : U32), t, z, 1, 4}, z, k, w, pat, Nil{}}, (t1 - t0 : Nat)), src)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)


# ---------------------------------------------------------------------------
# text demo: an object of several source blocks with sub-blocks (RFC 4.3 parameters), a quarter of the source packets of every block lost
# ---------------------------------------------------------------------------

def MSG() -> String:
  "RaptorQ (RFC 6330) written in Bend: the fountain code that recovers a file from any slightly larger than K subset of its encoding symbols. This object is cut into several source blocks (RFC 4.4.1.2), every block into sub-blocks, each block is encoded and decoded independently, in parallel."

def str_bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      []
    case SCon{h, tl}:
      (Char.to_u32(h) .&. 255 : U32) <> str_bytes(tl)

def bytes_str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case Con{h, tl}:
      SCon{Chr{h}, bytes_str(tl)}

def len_u32(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, tl}:
      len_u32(tl, (acc + 1 : U32))

def sym_or_nil(m: Maybe<&2, G.Vec>) -> G.Vec:
  match m:
    case None{}:
      G.VNil{}
    case Some{v}:
      v

def lost(+i: U32) -> Bool:
  U32.is_eq((i .&. 3 : U32), 1)

def lost_count(n: Nat, +i: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      lost_count(p, (i + 1 : U32), (acc + b2u(lost(i)) : U32))

def src_pick2(l: Bool, p: B.Pkt, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match l:
    case True{}:
      acc
    case False{}:
      p <> acc

def rcv_src(n: Nat, +i: U32, +sbn: U32, +obj: B.Obj, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match n:
    case 0n:
      acc
    case 1n+p:
      rcv_src(p, (i + 1 : U32), sbn, obj, src_pick2(lost(i), B.Pkt{sbn, i, sym_or_nil(B.Blocks.symbol(obj, sbn, i))}, acc))

def rcv_rep(n: Nat, +esi: U32, +sbn: U32, +obj: B.Obj, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match n:
    case 0n:
      acc
    case 1n+p:
      rcv_rep(p, (esi + 1 : U32), sbn, obj, B.Pkt{sbn, esi, sym_or_nil(B.Blocks.symbol(obj, sbn, esi))} <> acc)

def rcv_blocks(n: Nat, +sbn: U32, +lay: B.Lay, +obj: B.Obj, acc: List<&2, B.Pkt>) -> List<&2, B.Pkt>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +k = B.Blocks.block_k(lay, sbn)
      +extra = (lost_count(U32.to_nat(k), 0, 0) + 1 : U32)
      rcv_blocks(p, (sbn + 1 : U32), lay, obj, rcv_rep(U32.to_nat(extra), k, sbn, obj, rcv_src(U32.to_nat(k), 0, sbn, obj, acc)))

def text.dec(m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.print("decoding failed")
    case Some{d}:
      IO.print("decoded text : " ++ bytes_str(d))

def text.run(m: Maybe<&2, B.Obj>, +oti: B.Oti, +w: U32) -> IO(Unit):
  match m:
    case None{}:
      IO.print("encoding failed")
    case Some{+obj}:
      +lay = B.Blocks.layout(oti)
      +rv = rcv_blocks(U32.to_nat(B.Blocks.num_blocks(lay)), 0, lay, obj, Nil{})
      do IO<Unit>:
        IO.print("received " ++ U32.show(pk_len(rv, 0)) ++ " packets (a quarter of the source packets of every block lost, repair packets added)")
        text.dec(B.Blocks.decode_object(w, oti, rv))

def octets_str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{h, tl}:
      U32.show(h) ++ " " ++ octets_str(tl)

def lay_str(lay: B.Lay) -> String:
  match lay:
    case B.Lay{kt, kl, ks, zl, zs}:
      U32.show(zl) ++ " x " ++ U32.show(kl) ++ " + " ++ U32.show(zs) ++ " x " ++ U32.show(ks) ++ " symbols (Kt = " ++ U32.show(kt) ++ ")"

def text.oti(m: Maybe<&2, B.Oti>, +data: List<&2, U32>, +w: U32) -> IO(Unit):
  match m:
    case None{}:
      IO.print("no valid parameters")
    case Some{+oti}:
      +lay = B.Blocks.layout(oti)
      do IO<Unit>:
        IO.print("OTI: F=" ++ U32.show(B.Blocks.oti_f(oti)) ++ " T=" ++ U32.show(B.Blocks.oti_t(oti)) ++ " Z=" ++ U32.show(B.Blocks.oti_z(oti)) ++ " N=" ++ U32.show(B.Blocks.oti_n(oti)) ++ "  (12 octets: " ++ octets_str(B.Blocks.oti_bytes(oti)) ++ ")")
        IO.print("blocks: Z=" ++ U32.show(B.Blocks.num_blocks(lay)) ++ ", sizes " ++ lay_str(lay))
        text.run(B.Blocks.encode_object(w, oti, data), oti, w)

def Blocks_app3(+xs: List<&2, U32>) -> List<&2, U32>:
  B.Blocks.app(U32, xs, B.Blocks.app(U32, xs, xs))

def text(+z: U32, +w: U32) -> IO(Unit):
  +data = Blocks_app3(str_bytes(MSG()))
  do IO<Unit>:
    IO.print("original text (three times): " ++ bytes_str(data))
    text.oti(B.Blocks.params(U32.from_nat(List.length(&2, U32, data)), 16, 4, 100, 1), data, w)

# ---------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------

def nums(args: List<String>, acc: List<&2, U32>) -> List<&2, U32>:
  match args:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case a <> rest:
      nums(rest, rd(a, 0) <> acc)

def nth_u32(xs: List<&2, U32>, +i: U32, +d: U32) -> U32:
  match xs:
    case Nil{}:
      d
    case Con{x, rest}:
      match i:
        case 0:
          x
        case _:
          nth_u32(rest, (i - 1 : U32), d)

def first_char(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{h, tl}:
      Char.to_u32(h)

def or_w(+x: U32, +w: U32) -> U32:
  Bool.pick(U32, U32.is_eq(x, 0), w, x)

# bench Z K T [pat [W [fused]]]: pat = 1: a different ESI set per block (default 0: the same everywhere); W = number of leaf tasks of the
#   block tree (0 = Z: every block its own task, which balanced best, docs/multiblock.md); fused = 1: Blocks.encode_repair instead of encode_syms + repair
# text (also the default): the text demo
def run_cmd(+c: U32, +ns: List<&2, U32>, +w: U32) -> IO(Unit):
  match c:
    case 98:
      bench(nth_u32(ns, 0, 8), nth_u32(ns, 1, 100), nth_u32(ns, 2, 64), or_w(nth_u32(ns, 4, 0), nth_u32(ns, 0, 8)), nth_u32(ns, 3, 0), nth_u32(ns, 5, 0))
    case _:
      text(1, w)

def run_args(args: List<String>, +w: U32) -> IO(Unit):
  match args:
    case prog <> cmd <> rest:
      run_cmd(first_char(cmd), nums(rest, Nil{}), w)
    case _:
      text(1, w)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    w : U32 <- IO.thread_count()
    run_args(args, w)
