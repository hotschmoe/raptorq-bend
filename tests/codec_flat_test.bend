# The linear flat encoder (Codec.encoder_flat / encode_with_plan_flat / symbols_flat / out_vecs): same symbols as the Data encoder,
# for several block sizes and slicing depths (d = 0, 1, 3; T not a multiple of 16 / of 4 / odd word counts), a second call on the
# returned encoder, a plan reuse, the _auto variants, and the None cases.
#   bend tests/codec_flat_test.bend      (ALL PASS, exit 1 on failure)
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/raptorq.bend as Q
import ../src/solver.bend as S

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

# two generate calls on the same encoder (the arenas must survive the first), compared with the Data encoder's symbols
def gen2.c(v1: List<&2, G.Vec>, g2: Q.GenF, +n2: U32) -> List<&2, G.Vec> & List<&2, G.Vec>:
  match g2:
    case Q.GenF{eb, o2}:
      (v1, Q.Codec.out_vecs(n2, o2))

def gen2.b(g1: Q.GenF, +n1: U32, +n2: U32, +e2: U32) -> List<&2, G.Vec> & List<&2, G.Vec>:
  match g1:
    case Q.GenF{ea, o1}:
      gen2.c(Q.Codec.out_vecs(n1, o1), Q.Codec.symbols_flat(ea, e2, n2), n2)

def gen2(e: Q.EncF, +n1: U32, +n2: U32, +e1: U32, +e2: U32) -> List<&2, G.Vec> & List<&2, G.Vec>:
  gen2.b(Q.Codec.symbols_flat(e, e1, n1), n1, n2, e2)

def gen2.t(r: List<&2, G.Vec> & List<&2, G.Vec>, ref1: List<&2, G.Vec>, ref2: List<&2, G.Vec>) -> Bool:
  match r:
    case Tuple{a, b}:
      band(syms_eq(a, ref1), syms_eq(b, ref2))

def one(m: Q.MbF, ref: Maybe<&2, Q.Enc>, +k: U32, +t: U32, +d: U32, name: String) -> IO(U32):
  match m:
    case Q.NoF{}:
      do IO<U32>:
        IO.print("FAIL " ++ name ++ ": NoF")
        IO.pure(U32, 1)
    case Q.SomeF{e}:
      match ref:
        case Some{+r}:
          check(gen2.t(gen2(e, (k + 20 : U32), 37, 0, 3), Q.Codec.symbols(r, 0, (k + 20 : U32)), Q.Codec.symbols(r, 3, 37)), name ++ " symbols_flat (+ second call on the returned encoder) == symbols, K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " d=" ++ U32.show(d))
        case None{}:
          do IO<U32>:
            IO.print("FAIL reference encoder None")
            IO.pure(U32, 1)

def is_nof(m: Q.MbF) -> Bool:
  match m:
    case Q.NoF{}:
      True{}
    case Q.SomeF{e}:
      False{}

def run_case(+k: U32, +t: U32) -> IO(U32):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<U32>:
    c0 : U32 <- one(Q.Codec.encoder_flat(0, k, t, {src : List<&2, G.Vec>}), Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), k, t, 0, "encoder_flat")
    c1 : U32 <- one(Q.Codec.encoder_flat(1, k, t, {src : List<&2, G.Vec>}), Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), k, t, 1, "encoder_flat")
    c2 : U32 <- one(Q.Codec.encoder_flat(3, k, t, {src : List<&2, G.Vec>}), Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), k, t, 3, "encoder_flat")
    c3 : U32 <- one(Q.Codec.encode_with_plan_flat(2, k, t, Maybe.default(&2, S.Plan, Q.Codec.encoder_plan(k), S.Plan{0, 0, 0, 0, [], [], []}), {src : List<&2, G.Vec>}), Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), k, t, 2, "encode_with_plan_flat")
    ma : Q.MbF <- Q.Codec.encoder_flat_auto(k, t, {src : List<&2, G.Vec>})
    c4 : U32 <- one(ma, Q.Codec.encoder(k, t, {src : List<&2, G.Vec>}), k, t, 9, "encoder_flat_auto")
    IO.pure(U32, (c0 + c1 + c2 + c3 + c4 : U32))

def edge() -> IO(U32):
  do IO<U32>:
    c : U32 <- check(band(is_nof(Q.Codec.encoder_flat(0, 0, 16, [])), band(is_nof(Q.Codec.encoder_flat(0, 5, 16, [])), is_nof(Q.Codec.encoder_flat(2, 5, 0, [])))), "encoder_flat edge cases give NoF")
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
    b : U32 <- run_case(50, 5)
    c : U32 <- run_case(100, 36)
    d : U32 <- run_case(100, 64)
    e : U32 <- run_case(300, 512)
    f : U32 <- run_case(26, 1024)
    g : U32 <- edge()
    fin((a + b + c + d + e + f + g : U32))
