# Codec.encoder_auto / Codec.decode_auto (IO, Solver.solve_auto) must give the same bytes as the pure Codec.encoder /
# Codec.decode.  T >= 256 octets makes solve_auto slice the symbols over the threads (with --threads >= 2).
# Run: bend tests/codec_auto_test.bend   or   bend tests/codec_auto_test.bend -o cat && ./cat [--threads N]
# Prints one line per case and ALL PASS; exits 1 on any failure.
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/raptorq.bend as Q
import ../src/tables.bend as T
import ../src/rfc_funcs.bend as R
import ../src/constraints.bend as C

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

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

def bytes.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      bytes.go(p, lcg(x), U32.shrn(lcg(x), 24n) <> acc)

# Maybe<List<Sym>> equality (None == None)
def mb_eq(a: Maybe<&2, List<&2, G.Vec>>, b: Maybe<&2, List<&2, G.Vec>>) -> Bool:
  match a b:
    case Some{x} Some{y}:
      syms_eq(x, y)
    case None{} None{}:
      True{}
    case _ _:
      False{}

def odd2(b: Bool, +i: U32, +k: U32) -> U32:
  match b:
    case True{}:
      (k + i : U32)
    case False{}:
      i

def match_odd(+i: U32, +k: U32) -> U32:
  odd2(U32.is_eq((i .&. 1 : U32), 1), i, k)

# received: for ESI i in 0..k-1, odd i -> repair symbol k+i, even i -> source symbol i  (so half of the K are repair)
def rcv.go(n: Nat, +i: U32, +k: U32, +e: Q.Enc, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +esi = match_odd(i, k)
      rcv.go(p, (i - 1 : U32), k, e, Y.Rcv{esi, Q.Codec.symbol(e, esi)} <> acc)

def check(b: Bool, name: String) -> IO(U32):
  match b:
    case True{}:
      do IO<U32>:
        IO.print("PASS " ++ name)
        IO.pure(U32, 0)
    case False{}:
      do IO<U32>:
        IO.print("FAIL " ++ name)
        IO.pure(U32, 1)

# the sliced branch of decode_auto (Solver.auto_depth is 0 for blocks this small), forced with d = 3
def sliced_dec(+k: U32, +t: U32, rv: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  +sp = Maybe.default(&2, T.SP, R.params(k), T.SP{0, 0, 0, 0, 0, 0})
  Q.dec.auto_go(3, sp, k, Q.append_rows(C.fixed(sp, t), C.received_rows(sp, k, rv)))

def case2(m: Maybe<&2, Q.Enc>, ma: Maybe<&2, Q.Enc>, +k: U32, +t: U32, src: List<&2, G.Vec>) -> IO(U32):
  match m ma:
    case Some{+e} Some{+ea}:
      +rv = rcv.go(U32.to_nat(k), (k - 1 : U32), k, e, [])
      do IO<U32>:
        c1 : U32 <- check(syms_eq(Q.Codec.symbols(e, 0, (k + 20 : U32)), Q.Codec.symbols(ea, 0, (k + 20 : U32))), "encoder_auto symbols == encoder, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t))
        +da : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_auto(k, t, rv)
        +dp : Maybe<&2, List<&2, G.Vec>> <- IO.pure(Maybe<&2, List<&2, G.Vec>>, Q.Codec.decode(k, t, rv))
        c2 : U32 <- check(mb_eq(dp, da), "decode_auto == decode, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t))
        c3 : U32 <- check(mb_eq(da, Some{src}), "decode_auto recovers the source, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t))
        c4 : U32 <- check(mb_eq(sliced_dec(k, t, rv), dp), "sliced (d=3) decode == decode, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t))
        c5 : U32 <- check(syms_eq(Q.Codec.symbols_par(e, 3, 0, (k + 20 : U32)), Q.Codec.symbols(e, 0, (k + 20 : U32))), "symbols_par d=3 == symbols, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t))
        c6 : U32 <- check(syms_eq(Q.Codec.symbols_par(e, 2, 3, 37), Q.Codec.symbols(e, 3, 37)), "symbols_par d=2 (esi0=3, n=37) == symbols, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t))
        IO.pure(U32, (c1 + c2 + c3 + c4 + c5 + c6 : U32))
    case _ _:
      do IO<U32>:
        IO.print("FAIL encoder returned None")
        IO.pure(U32, 1)

def run_case(+k: U32, +t: U32) -> IO(U32):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<U32>:
    ea : Maybe<&2, Q.Enc> <- Q.Codec.encoder_auto(k, t, {src : List<&2, G.Vec>})
    case2(Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), ea, k, t, src)

def is_none_e(m: Maybe<&2, Q.Enc>) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{e}:
      False{}

# invalid inputs give None from the IO variants too
def edge() -> IO(U32):
  do IO<U32>:
    e0 : Maybe<&2, Q.Enc> <- Q.Codec.encoder_auto(0, 16, [])
    e1 : Maybe<&2, Q.Enc> <- Q.Codec.encoder_auto(5, 16, [])
    d0 : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_auto(5, 16, [])
    c : U32 <- check(band(is_none_e(e0), band(is_none_e(e1), mb_eq(d0, None{}))), "edge cases give None")
    IO.pure(U32, c)

def fin(+n: U32) -> IO(Unit):
  match n:
    case 0:
      IO.print("ALL PASS")
    case _:
      IO.die(Unit, 1, "FAILURES: " ++ U32.show(n))

def main() -> IO(Unit):
  do IO<Unit>:
    a : U32 <- run_case(10, 16)
    b : U32 <- run_case(100, 16)
    c : U32 <- run_case(100, 256)
    d : U32 <- run_case(100, 1024)
    e : U32 <- run_case(1000, 16)
    f : U32 <- run_case(300, 512)
    g : U32 <- run_case(1000, 256)
    h : U32 <- edge()
    i : U32 <- run_case(100, 36)
    j : U32 <- run_case(50, 100)
    fin((a + b + c + d + e + f + g + h + i + j : U32))

