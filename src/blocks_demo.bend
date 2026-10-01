# Multi-block object demo and benchmark for src/blocks.bend (docs/multiblock.md).
#   bend src/blocks_demo.bend                          encode a text as a 5-block object (T=16), lose symbols in every block, decode
#   bend src/blocks_demo.bend -o build/blocks_demo
#   ./build/blocks_demo [--threads W] -- bench Z K T [pat]
#        Z source blocks of K symbols of T octets (T a multiple of 4; the object is Z*K*T octets, N = 1, Al = 4), W workers:
#        phases (wall ms each): gen (source symbols, parallel), enc (plans + all blocks), rep (K*7/8 repair symbols per block),
#        dec (decode from K symbols per block, 7/8 of them repair), then an untimed verification.  pat = 0: every block receives
#        the same ESIs (one shared plan per K), pat = 1: a different ESI set per block (every block builds its own plan).
#   ./build/blocks_demo -- text Z                      the same text demo with Z blocks
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

def report(+z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +gen: Nat, +enc: Nat, +rep: Nat, +dec: Nat, +ver: Nat, +ok: U32) -> IO(Unit):
  IO.print("BLOCKS Z=" ++ U32.show(z) ++ " K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " w=" ++ U32.show(w) ++ " pat=" ++ U32.show(pat) ++ " gen_ms=" ++ Nat.show(gen) ++ " enc_ms=" ++ Nat.show(enc) ++ " rep_ms=" ++ Nat.show(rep) ++ " dec_ms=" ++ Nat.show(dec) ++ " verify_ms=" ++ Nat.show(ver) ++ " ok=" ++ U32.show(ok))

# stage 5: verify (untimed in the table)
def st_ver(res: Maybe<&2, List<&2, List<&2, G.Vec>>>, +src: List<&2, List<&2, G.Vec>>, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +te: Nat, +tr: Nat, +td: Nat) -> IO(Unit):
  match res:
    case None{}:
      IO.die(Unit, 1, "FAIL: decode returned None")
    case Some{out}:
      do IO<Unit>:
        +t5 : Nat <- IO.now()
        +ok : U32 <- IO.pure(U32, b2u(blocks_eq(out, src)))
        IO.print("verified " ++ U32.show(ok))
        +t6 : Nat <- IO.now()
        report(z, k, t, w, pat, tg, te, tr, td, (t6 - t5 : Nat), ok)

# stage 4: decode
def st_dec(+oti: B.Oti, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +te: Nat, +tr: Nat, +src: List<&2, List<&2, G.Vec>>, +rr: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  +pk = all_pkts(src, rr, pat, 0, k, Nil{})
  do IO<Unit>:
    +n : U32 <- IO.pure(U32, pk_len(pk, 0))
    IO.print("packets " ++ U32.show(n))
    +t3 : Nat <- IO.now()
    +res : Maybe<&2, List<&2, List<&2, G.Vec>>> <- IO.pure(Maybe<&2, List<&2, List<&2, G.Vec>>>, B.Blocks.decode_syms(w, oti, pk))
    IO.print("decoded " ++ U32.show(some_dec(res)))
    +t4 : Nat <- IO.now()
    st_ver(res, src, z, k, t, w, pat, tg, te, tr, (t4 - t3 : Nat))

# stage 3: repair symbols of every block
def st_rep(m: Maybe<&2, B.Obj>, +oti: B.Oti, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +te: Nat, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encode_syms returned None")
    case Some{obj}:
      do IO<Unit>:
        +t2 : Nat <- IO.now()
        +rr : List<&2, List<&2, G.Vec>> <- IO.pure(List<&2, List<&2, G.Vec>>, B.Blocks.repair(w, obj, (n_rep(k) + 4 : U32)))
        IO.print("repair checksum " ++ U32.show(last_chk(rr, 0)))
        +t3 : Nat <- IO.now()
        st_dec(oti, z, k, t, w, pat, tg, te, (t3 - t2 : Nat), src, rr)

def st_fin(m: Maybe<&2, List<&2, List<&2, G.Vec>>>, +oti: B.Oti, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +te: Nat, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encode_repair returned None")
    case Some{rr}:
      st_dec(oti, z, k, t, w, pat, tg, te, 0n, src, rr)

# stage 2 (fused): encode + repair symbols in one parallel region (arena path, no Obj)
def st_fused(+oti: B.Oti, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    +m : Maybe<&2, List<&2, List<&2, G.Vec>>> <- IO.pure(Maybe<&2, List<&2, List<&2, G.Vec>>>, B.Blocks.encode_repair(w, oti, (n_rep(k) + 4 : U32), src))
    IO.print("encoded+repaired " ++ U32.show(some_dec(m)))
    +t2 : Nat <- IO.now()
    st_fin(m, oti, z, k, t, w, pat, tg, (t2 - t1 : Nat), src)

# stage 2: encode all blocks
def st_enc(+oti: B.Oti, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    +m : Maybe<&2, B.Obj> <- IO.pure(Maybe<&2, B.Obj>, B.Blocks.encode_syms(w, oti, src))
    IO.print("encoded " ++ U32.show(some_enc(m)))
    +t2 : Nat <- IO.now()
    st_rep(m, oti, z, k, t, w, pat, tg, (t2 - t1 : Nat), src)

# stage 1: generate the source data
def st_pick(fused: Bool, +oti: B.Oti, +z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +tg: Nat, +src: List<&2, List<&2, G.Vec>>) -> IO(Unit):
  match fused:
    case True{}:
      st_fused(oti, z, k, t, w, pat, tg, src)
    case False{}:
      st_enc(oti, z, k, t, w, pat, tg, src)

def bench(+z: U32, +k: U32, +t: U32, +w: U32, +pat: U32, +fused: U32) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +src : List<&2, List<&2, G.Vec>> <- IO.pure(List<&2, List<&2, G.Vec>>, gen_object(w, z, k, t))
    IO.print("source checksum " ++ U32.show(fold_blocks(src, 0)))
    +t1 : Nat <- IO.now()
    st_pick(U32.is_eq(fused, 1), B.Oti{(z * k * t : U32), t, z, 1, 4}, z, k, t, w, pat, (t1 - t0 : Nat), src)

# ---------------------------------------------------------------------------
# calibration: the same block tree over a pure register loop (no memory, no allocation): what the machine itself can do in parallel
#   ./blocks_demo [--threads W] -- calib Z ITERS [W]     Z tasks of ITERS loop iterations each; prints  CALIB ... ms=..
# ---------------------------------------------------------------------------

def spin(n: Nat, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      spin(p, (acc * 1664525 + 1013904223 : U32))

def cal_leaf(n: Nat, +it: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      cal_leaf(p, it, (acc + spin(U32.to_nat(it), acc) : U32))

def cal_range(+d: Nat, lf: Bool, +w: U32, +n: U32, +it: U32) -> U32:
  match d:
    case 0n:
      cal_leaf(U32.to_nat(n), it, 1)
    case 1n+q:
      match lf:
        case True{}:
          cal_leaf(U32.to_nat(n), it, 1)
        case False{}:
          +wl = (w / 2 : U32)
          +nl = B.n_left(w, n)
          +wr = (w - wl : U32)
          +nr = (n - nl : U32)
          a b = cal_range(q, B.is_leaf(wl, nl), wl, nl, it) cal_range(q, B.is_leaf(wr, nr), wr, nr, it)
          (a + b : U32)

def calib(+z: U32, +it: U32, +w: U32) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +r : U32 <- IO.pure(U32, cal_range(B.levels(w), B.is_leaf(w, z), w, z, it))
    IO.print("result " ++ U32.show(r))
    +t1 : Nat <- IO.now()
    IO.print("CALIB Z=" ++ U32.show(z) ++ " iters=" ++ U32.show(it) ++ " w=" ++ U32.show(w) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

# bench Z K T [pat [W [fused]]]: W overrides the worker count of the block tree (default: the thread count of the process),
# fused = 1: Blocks.encode_repair instead of encode_syms + repair
def run_args(args: List<String>, +w: U32) -> IO(Unit):
  match args:
    case prog <> cmd <> zs <> its <> ws <> Nil{}:
      calib(rd(zs, 64), rd(its, 50000000), rd(ws, w))
    case prog <> cmd <> zs <> ks <> ts <> ps <> ws <> fs <> rest:
      bench(rd(zs, 8), rd(ks, 100), rd(ts, 64), rd(ws, w), rd(ps, 0), rd(fs, 0))
    case prog <> cmd <> zs <> ks <> ts <> ps <> ws <> Nil{}:
      bench(rd(zs, 8), rd(ks, 100), rd(ts, 64), rd(ws, w), rd(ps, 0), 0)
    case prog <> cmd <> zs <> ks <> ts <> ps <> Nil{}:
      bench(rd(zs, 8), rd(ks, 100), rd(ts, 64), w, rd(ps, 0), 0)
    case prog <> cmd <> zs <> ks <> ts <> Nil{}:
      bench(rd(zs, 8), rd(ks, 100), rd(ts, 64), w, 0, 0)
    case _:
      IO.print("usage: blocks_demo [--threads W] -- bench Z K T [pat [workers [fused]]]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    w : U32 <- IO.thread_count()
    run_args(args, w)
