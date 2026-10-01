# Scaling lab for src/blocks.bend (docs/multiblock.md): plain forks vs `!` calls over the block tree, a register-loop calibration of the same
# tree, and private-plan chunks.  Needs clang >= 19 (the `!` call sites); put a dir whose `clang` is clang-19 first in PATH:
#   export PATH="$HOME/.bend/bin:<dir with clang -> /usr/bin/clang-19>:/usr/bin:/bin" BEND_NO_TELEMETRY=1
#   bend tools/blocks_lab.bend -o build/blocks_lab
#   ./build/blocks_lab --threads N [--gpu off] -- calib Z ITERS W [bang]      Z tasks of ITERS loop iterations (pure registers)
#   ./build/blocks_lab --threads N [--gpu off] -- bench Z K T W [bang]        encode+repair (fused) and decode of Z blocks of K symbols
#   ./build/blocks_lab --threads N [--gpu off] -- priv Z K T W [bang]         same, but W independent sub-objects (private plans, no sharing)
# Prints  CALIB ... ms=..   or   LAB Z=.. K=.. T=.. w=.. bang=.. enc_ms=.. dec_ms=.. ok=..
import Base
import ../src/gf256.bend as G
import ../src/blocks.bend as B
import ../src/blocks_demo.bend as D

# ---------------------------------------------------------------------------
# calibration: the block tree over a pure register loop (no memory, no allocation)
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

def cal_run(+bang: U32, +z: U32, +it: U32, +w: U32) -> U32:
  match bang:
    case 0:
      cal_range(B.levels(w), B.is_leaf(w, z), w, z, it)
    case _:
      cal_range!(B.levels(w), B.is_leaf(w, z), w, z, it)

def calib(+z: U32, +it: U32, +w: U32, +bang: U32) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +r : U32 <- IO.pure(U32, cal_run(bang, z, it, w))
    IO.print("result " ++ U32.show(r))
    +t1 : Nat <- IO.now()
    IO.print("CALIB Z=" ++ U32.show(z) ++ " iters=" ++ U32.show(it) ++ " w=" ++ U32.show(w) ++ " bang=" ++ U32.show(bang) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

# ---------------------------------------------------------------------------
# the real workload: encode + repair (fused) and decode of an object
# ---------------------------------------------------------------------------

def enc_run(+bang: U32, +w: U32, +oti: B.Oti, +n: U32, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match bang:
    case 0:
      B.Blocks.encode_repair(w, oti, n, src)
    case _:
      B.Blocks.encode_repair!(w, oti, n, src)

def dec_run(+bang: U32, +w: U32, +oti: B.Oti, pk: List<&2, B.Pkt>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match bang:
    case 0:
      B.Blocks.decode_syms(w, oti, pk)
    case _:
      B.Blocks.decode_syms!(w, oti, pk)

def lab_fin(res: Maybe<&2, List<&2, List<&2, G.Vec>>>, +src: List<&2, List<&2, G.Vec>>, +z: U32, +k: U32, +t: U32, +w: U32, +bang: U32, +te: Nat, +td: Nat) -> IO(Unit):
  match res:
    case None{}:
      IO.die(Unit, 1, "FAIL: decode returned None")
    case Some{out}:
      IO.print("LAB Z=" ++ U32.show(z) ++ " K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " w=" ++ U32.show(w) ++ " bang=" ++ U32.show(bang) ++ " enc_ms=" ++ Nat.show(te) ++ " dec_ms=" ++ Nat.show(td) ++ " ok=" ++ U32.show(D.b2u(D.blocks_eq(out, src))))

def lab_dec(m: Maybe<&2, List<&2, List<&2, G.Vec>>>, +oti: B.Oti, +src: List<&2, List<&2, G.Vec>>, +z: U32, +k: U32, +t: U32, +w: U32, +bang: U32, +te: Nat) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encode_repair returned None")
    case Some{rr}:
      +pk = D.all_pkts(src, rr, 0, 0, k, Nil{})
      do IO<Unit>:
        IO.print("packets " ++ U32.show(D.pk_len(pk, 0)))
        +t3 : Nat <- IO.now()
        +res : Maybe<&2, List<&2, List<&2, G.Vec>>> <- IO.pure(Maybe<&2, List<&2, List<&2, G.Vec>>>, dec_run(bang, w, oti, pk))
        IO.print("decoded " ++ U32.show(D.some_dec(res)))
        +t4 : Nat <- IO.now()
        lab_fin(res, src, z, k, t, w, bang, te, (t4 - t3 : Nat))

def lab_enc(+src: List<&2, List<&2, G.Vec>>, +z: U32, +k: U32, +t: U32, +w: U32, +bang: U32) -> IO(Unit):
  +oti = {B.Oti{(z * k * t : U32), t, z, 1, 4} : B.Oti}
  do IO<Unit>:
    IO.print("source checksum " ++ U32.show(D.fold_blocks(src, 0)))
    +t1 : Nat <- IO.now()
    +m : Maybe<&2, List<&2, List<&2, G.Vec>>> <- IO.pure(Maybe<&2, List<&2, List<&2, G.Vec>>>, enc_run(bang, w, oti, (D.n_rep(k) + 4 : U32), src))
    IO.print("encoded+repaired " ++ U32.show(D.some_dec(m)))
    +t2 : Nat <- IO.now()
    lab_dec(m, oti, src, z, k, t, w, bang, (t2 - t1 : Nat))

def lab(+z: U32, +k: U32, +t: U32, +w: U32, +bang: U32) -> IO(Unit):
  do IO<Unit>:
    +src : List<&2, List<&2, G.Vec>> <- IO.pure(List<&2, List<&2, G.Vec>>, D.gen_object(w, z, k, t))
    lab_enc(src, z, k, t, w, bang)

# ---------------------------------------------------------------------------
# private plans: W independent sub-objects (each Z/W blocks of the same K, so Z/W must be integral here), every sub-object
# computes its own plan inside its task; the sub-objects are encoded and decoded by W tasks of the SAME block tree shape
# ---------------------------------------------------------------------------

def chunk_dec(res: Maybe<&2, List<&2, List<&2, G.Vec>>>, src: List<&2, List<&2, G.Vec>>) -> U32:
  match res:
    case None{}:
      0
    case Some{out}:
      D.b2u(D.blocks_eq(out, src))

# one chunk: encode + repair, then decode, all with one worker; result = whether the decode equals the source
def chunk_ok(m: Maybe<&2, List<&2, List<&2, G.Vec>>>, +oti: B.Oti, +src: List<&2, List<&2, G.Vec>>, +k: U32) -> U32:
  match m:
    case None{}:
      0
    case Some{rr}:
      chunk_dec(B.Blocks.decode_syms(1, oti, D.all_pkts(src, rr, 0, 0, k, Nil{})), src)

def chunk_one(+n: U32, +k: U32, +t: U32, src: List<&2, List<&2, G.Vec>>) -> U32:
  +s = src
  +oti = {B.Oti{(n * k * t : U32), t, n, 1, 4} : B.Oti}
  chunk_ok(B.Blocks.encode_repair(1, oti, (D.n_rep(k) + 4 : U32), s), oti, s, k)

def chunk_tree(+d: Nat, lf: Bool, +w: U32, +n: U32, +k: U32, +t: U32, +src: List<&2, List<&2, G.Vec>>) -> U32:
  match d:
    case 0n:
      chunk_one(n, k, t, src)
    case 1n+q:
      match lf:
        case True{}:
          chunk_one(n, k, t, src)
        case False{}:
          +wl = (w / 2 : U32)
          +nl = B.n_left(w, n)
          +wr = (w - wl : U32)
          +nr = (n - nl : U32)
          a b = chunk_tree(q, B.is_leaf(wl, nl), wl, nl, k, t, src) chunk_tree(q, B.is_leaf(wr, nr), wr, nr, k, t, List.drop(&2, List<&2, G.Vec>, src, U32.to_nat(nl)))
          (a + b : U32)

def chunk_run(+bang: U32, +w: U32, +z: U32, +k: U32, +t: U32, src: List<&2, List<&2, G.Vec>>) -> U32:
  match bang:
    case 0:
      chunk_tree(B.levels(w), B.is_leaf(w, z), w, z, k, t, src)
    case _:
      chunk_tree!(B.levels(w), B.is_leaf(w, z), w, z, k, t, src)

def chunk(+z: U32, +k: U32, +t: U32, +w: U32, +bang: U32) -> IO(Unit):
  do IO<Unit>:
    +src : List<&2, List<&2, G.Vec>> <- IO.pure(List<&2, List<&2, G.Vec>>, D.gen_object(w, z, k, t))
    IO.print("source checksum " ++ U32.show(D.fold_blocks(src, 0)))
    +t1 : Nat <- IO.now()
    +ok : U32 <- IO.pure(U32, chunk_run(bang, w, z, k, t, src))
    IO.print("blocks recovered " ++ U32.show(ok))
    +t2 : Nat <- IO.now()
    IO.print("CHUNK Z=" ++ U32.show(z) ++ " K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " w=" ++ U32.show(w) ++ " bang=" ++ U32.show(bang) ++ " enc_dec_ms=" ++ Nat.show((t2 - t1 : Nat)) ++ " ok_blocks=" ++ U32.show(ok))

# ---------------------------------------------------------------------------

def nth(xs: List<&2, U32>, +i: U32, +d: U32) -> U32:
  D.nth_u32(xs, i, d)

def run_cmd(+c: U32, +ns: List<&2, U32>, +w: U32) -> IO(Unit):
  match c:
    case 99:
      calib(nth(ns, 0, 64), nth(ns, 1, 50000000), D.or_w(nth(ns, 2, 0), w), nth(ns, 3, 0))
    case 98:
      lab(nth(ns, 0, 16), nth(ns, 1, 1000), nth(ns, 2, 1024), D.or_w(nth(ns, 3, 0), w), nth(ns, 4, 0))
    case 112:
      chunk(nth(ns, 0, 16), nth(ns, 1, 1000), nth(ns, 2, 1024), D.or_w(nth(ns, 3, 0), w), nth(ns, 4, 0))
    case _:
      IO.print("usage: blocks_lab [--threads N] -- calib|bench|priv ...")

def run_args(args: List<String>, +w: U32) -> IO(Unit):
  match args:
    case prog <> cmd <> rest:
      run_cmd(D.first_char(cmd), D.nums(rest, Nil{}), w)
    case _:
      IO.print("usage: blocks_lab [--threads N] -- calib|bench|priv ...")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    w : U32 <- IO.thread_count()
    run_args(args, w)
