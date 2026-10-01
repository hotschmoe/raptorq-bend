# RaptorQ demo and benchmark for src/raptorq.bend (docs/codec.md).
#   bend src/raptorq_demo.bend                 encode a text, drop source symbols, decode from the rest, print it
#   bend src/raptorq_demo.bend -- bench K M T  K source symbols of T octets (default T=16), M=0: encoder only (+20 repair
#                                               symbols), M=1: also decode after losing 1/4 of the source symbols,
#                                               M=2 / M=3: like 0 / 1 with Codec.encoder_auto / decode_auto (symbols are
#                                               sliced over the threads when T >= 256: ./demo --threads 12 -- bench 1000 3 1024)
# Compiled: bend src/raptorq_demo.bend -o demo && ./demo -- bench 1000 1 16    (system clang first in PATH, see CLAUDE.md)
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./raptorq.bend as Q

def MSG() -> String:
  "RaptorQ (RFC 6330) written in Bend: the fountain code that recovers a file from any slightly larger than K subset of its encoding symbols."

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

def b2u(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0

# 'lost' = a source ESI that is dropped: every fourth one (ESI % 4 == 1)
def lost(+esi: U32) -> Bool:
  U32.is_eq((esi .&. 3 : U32), 1)

def count_lost(n: Nat, +esi: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      count_lost(p, (esi + 1 : U32), (acc + b2u(lost(esi)) : U32))

def keep.go(b: Bool, +esi: U32, +e: Q.Enc, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match b:
    case True{}:
      acc
    case False{}:
      Y.Rcv{esi, Q.Codec.symbol(e, esi)} <> acc

# received = surviving source symbols (ascending) then `extra` repair symbols K.. ; built back to front
def rcv.rep(n: Nat, +esi: U32, +e: Q.Enc, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match n:
    case 0n:
      acc
    case 1n+p:
      rcv.rep(p, (esi - 1 : U32), e, Y.Rcv{esi, Q.Codec.symbol(e, esi)} <> acc)

def rcv.src(n: Nat, +esi: U32, +e: Q.Enc, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match n:
    case 0n:
      acc
    case 1n+p:
      rcv.src(p, (esi - 1 : U32), e, keep.go(lost(esi), esi, e, acc))

def received(+e: Q.Enc, +k: U32) -> List<&2, Y.Rcv>:
  +extra = (count_lost(U32.to_nat(k), 0, 0) + 1 : U32)
  rcv.src(U32.to_nat(k), (k - 1 : U32), e, rcv.rep(U32.to_nat(extra), (k + extra - 1 : U32), e, []))

def esis(xs: List<&2, Y.Rcv>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case Con{r, tl}:
      match r:
        case Y.Rcv{esi, sym}:
          esi <> esis(tl)

def show_list(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{h, tl}:
      U32.show(h) ++ " " ++ show_list(tl)

# ---------------------------------------------------------------------------
# text demo
# ---------------------------------------------------------------------------

def demo.dec(res: Maybe<&2, List<&2, G.Vec>>, +t: U32, +len: U32) -> IO(Unit):
  match res:
    case None{}:
      IO.print("decoding failed")
    case Some{out}:
      IO.print("decoded text : " ++ bytes_str(Q.Codec.join(out, t, len)))

def demo.run(m: Maybe<&2, Q.Enc>, +k: U32, +t: U32, +len: U32) -> IO(Unit):
  match m:
    case None{}:
      IO.print("encoder failed")
    case Some{+e}:
      +rv = received(e, k)
      do IO<Unit>:
        IO.print("received ESIs: " ++ show_list(esis(rv)) ++ "(source ESIs < " ++ U32.show(k) ++ " are systematic; the others are repair symbols)")
        demo.dec(Q.Codec.decode(k, t, rv), t, len)

def demo() -> IO(Unit):
  do IO<Unit>:
    +data : List<&2, U32> <- IO.pure(List<&2, U32>, str_bytes(MSG()))
    +t : U32 <- IO.pure(U32, 16)
    +len : U32 <- IO.pure(U32, U32.from_nat(List.length(&2, U32, data)))
    +k : U32 <- IO.pure(U32, Q.Codec.k_of(len, t))
    IO.print("original text: " ++ MSG())
    IO.print("T=" ++ U32.show(t) ++ " octets, " ++ U32.show(len) ++ " bytes -> K=" ++ U32.show(k) ++ " source symbols")
    demo.run(Q.Codec.encoder(k, t, Q.Codec.split(data, t)), k, t, len)

# ---------------------------------------------------------------------------
# benchmark
# ---------------------------------------------------------------------------

def bytes.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      bytes.go(p, lcg(x), U32.shrn(lcg(x), 24n) <> acc)

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

def bench.ok(b: Bool) -> IO(Unit):
  match b:
    case True{}:
      IO.print("decode OK (source recovered bit-exactly)")
    case False{}:
      IO.die(Unit, 1, "FAIL: decoded symbols differ")

def bench.dec(res: Maybe<&2, List<&2, G.Vec>>, src: List<&2, G.Vec>) -> IO(Unit):
  match res:
    case None{}:
      IO.die(Unit, 1, "FAIL: decode returned None")
    case Some{out}:
      bench.ok(syms_eq(out, src))

def bench.mode(mode: U32, +e: Q.Enc, +k: U32, +t: U32, src: List<&2, G.Vec>) -> IO(Unit):
  match mode:
    case 0:
      IO.pure(Unit, Unit{})
    case _:
      bench.dec(Q.Codec.decode(k, t, received(e, k)), src)

def bench.go(m: Maybe<&2, Q.Enc>, +mode: U32, +k: U32, +t: U32, src: List<&2, G.Vec>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encoder returned None")
    case Some{+e}:
      do IO<Unit>:
        IO.print("encoder done; checksum of 20 repair symbols: " ++ U32.show(fold_syms(Q.Codec.symbols(e, k, 20), 0)))
        bench.mode(mode, e, k, t, src)

# auto-parallel variants (Codec.encoder_auto / decode_auto): modes 2 (encode) and 3 (encode + decode)
def auto.dec(res: Maybe<&2, List<&2, G.Vec>>, src: List<&2, G.Vec>) -> IO(Unit):
  bench.dec(res, src)

def auto.mode(+mode: U32, +e: Q.Enc, +k: U32, +t: U32, src: List<&2, G.Vec>) -> IO(Unit):
  match mode:
    case 2:
      IO.pure(Unit, Unit{})
    case _:
      do IO<Unit>:
        r : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_auto(k, t, received(e, k))
        auto.dec(r, src)

def auto.go(m: Maybe<&2, Q.Enc>, +mode: U32, +k: U32, +t: U32, src: List<&2, G.Vec>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encoder_auto returned None")
    case Some{+e}:
      do IO<Unit>:
        IO.print("encoder_auto done; checksum of 20 repair symbols: " ++ U32.show(fold_syms(Q.Codec.symbols(e, k, 20), 0)))
        auto.mode(mode, e, k, t, src)

def bench.auto(+k: U32, +mode: U32, +t: U32) -> IO(Unit):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<Unit>:
    IO.print("bench (auto) K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " mode=" ++ U32.show(mode))
    m : Maybe<&2, Q.Enc> <- Q.Codec.encoder_auto(k, t, {src : List<&2, G.Vec>})
    auto.go(m, mode, k, t, src)

def bench(+k: U32, +mode: U32, +t: U32) -> IO(Unit):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<Unit>:
    IO.print("bench K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " mode=" ++ U32.show(mode))
    bench.go(Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), mode, k, t, src)

def sel2(b: Bool, +k: U32, +mode: U32, +t: U32) -> IO(Unit):
  match b:
    case True{}:
      bench.auto(k, mode, t)
    case False{}:
      bench(k, mode, t)

def bench.sel(+k: U32, +mode: U32, +t: U32) -> IO(Unit):
  sel2(U32.is_ge(mode, 2), k, mode, t)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> cmd <> ks <> ms <> ts <> rest:
      bench.sel(rd(ks, 10), rd(ms, 0), rd(ts, 16))
    case prog <> cmd <> ks <> ms <> Nil{}:
      bench.sel(rd(ks, 10), rd(ms, 0), 16)
    case _:
      demo()

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
