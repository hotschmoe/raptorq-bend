# Symbol-side scaling of ONE block: Solver.apply (sequential) vs Solver.apply_par(d) on the encoder system of K source symbols.
#   bend tools/scaling/apply_par.bend -o build/scaling/apply_par ; ./build/scaling/apply_par [--threads N] -- <K> <T octets> <d>
# Prints  APPLY K= T= d= threads= plan_ms= seq_ms= par_ms= ok=   (ok = the sliced result equals the sequential one, word for word)
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as TB
import ../../src/rfc_funcs.bend as R
import ../../src/solver.bend as S
import ../../src/raptorq.bend as Q
import ../../src/flat.bend as F

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

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
      fold_syms(tl, fold_words(G.Vec.to_list(v, Nil{}), acc))

def b2u(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0

def ck.fin(r: Array<U32> & U32) -> U32:
  (a, x) = r
  x

def ar_ck(ar: F.Ar) -> U32:
  match ar:
    case F.Ar{a, wu, ca, sc}:
      ck.fin(Array.get(U32, a, sc))

def pg_ck(pg: S.Pg) -> U32:
  match pg:
    case S.Pg{p, m}:
      match m:
        case S.Pm{l, nrows, npiv, ntr, nin}:
          (nin + ck.fin(Array.get(U32, p, 0)) : U32)

def prog1(pg: S.Pg, +rhs: List<&2, G.Vec>) -> U32:
  match pg:
    case S.Pg{p, m}:
      ar_ck(S.Solver.apply_prog(m, p, rhs))

def leaf0(pg: S.Pg, +d: Nat, +rhs: List<&2, G.Vec>) -> U32:
  match pg:
    case S.Pg{p, m}:
      fold_syms(S.pa.leaf(m, p, S.slice_syms(rhs, d, 0)), 0)

def leaf0a(pg: S.Pg, +d: Nat, +rhs: List<&2, G.Vec>) -> U32:
  match pg:
    case S.Pg{p, m}:
      prog1(S.Pg{p, m}, S.slice_syms(rhs, d, 0))

def len_syms(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len_syms(t, (acc + 1 : U32))

def run(m: Maybe<&2, S.Plan>, +sp: TB.SP, +k: U32, +t: U32, +d: U32, +tp: Nat, src: List<&2, G.Vec>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "None")
    case Some{+plan}:
      +rhs = Q.wp.rhs(sp, k, t, src)
      do IO<Unit>:
        +thr : U32 <- IO.thread_count()
        +t0 : Nat <- IO.now()
        +r1 : List<&2, G.Vec> <- IO.pure(List<&2, G.Vec>, S.Solver.apply(plan, rhs))
        +n1 : U32 <- IO.pure(U32, len_syms(r1, 0))
        +t1 : Nat <- IO.now()
        +h1 : U32 <- IO.pure(U32, fold_syms(r1, 0))
        +t1b : Nat <- IO.now()
        +r2 : List<&2, G.Vec> <- IO.pure(List<&2, G.Vec>, S.Solver.apply_par(d, plan, rhs))
        +n2 : U32 <- IO.pure(U32, len_syms(r2, 0))
        +t2 : Nat <- IO.now()
        +h2 : U32 <- IO.pure(U32, fold_syms(r2, 0))
        +t2b : Nat <- IO.now()
        +c3 : U32 <- IO.pure(U32, pg_ck(S.Solver.prog(plan)))
        +t3 : Nat <- IO.now()
        +c4 : U32 <- IO.pure(U32, prog1(S.Solver.prog(plan), rhs))
        +t4 : Nat <- IO.now()
        +c5 : U32 <- IO.pure(U32, leaf0(S.Solver.prog(plan), 3n, rhs))
        +t5 : Nat <- IO.now()
        +c6 : U32 <- IO.pure(U32, leaf0a(S.Solver.prog(plan), 3n, rhs))
        +t6 : Nat <- IO.now()
        IO.print("LEAF d=3 compile+leaf+fold_ms=" ++ Nat.show((t5 - t4 : Nat)) ++ " compile+arena_only_ms=" ++ Nat.show((t6 - t5 : Nat)))
        IO.print("PROG compile_ms=" ++ Nat.show((t3 - t2b : Nat)) ++ " compile+apply_prog_1slice_ms=" ++ Nat.show((t4 - t3 : Nat)))
        IO.print("APPLY K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " d=" ++ U32.show(d) ++ " threads=" ++ U32.show(thr) ++ " plan_ms=" ++ Nat.show(tp) ++ " seq_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " seq_fold_ms=" ++ Nat.show((t1b - t1 : Nat)) ++ " par_ms=" ++ Nat.show((t2 - t1b : Nat)) ++ " par_fold_ms=" ++ Nat.show((t2b - t2 : Nat)) ++ " ok=" ++ U32.show(b2u(U32.is_eq(h1, h2))))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def bench(+k: U32, +t: U32, +d: U32) -> IO(Unit):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<Unit>:
    +sp : TB.SP <- IO.pure(TB.SP, Maybe.default(&2, TB.SP, R.params(k), TB.SP{0, 0, 0, 0, 0, 0}))
    +t0 : Nat <- IO.now()
    +pm : Maybe<&2, S.Plan> <- IO.pure(Maybe<&2, S.Plan>, Q.Codec.encoder_plan(k))
    +t1 : Nat <- IO.now()
    run(pm, sp, k, t, d, (t1 - t0 : Nat), src)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ts <> ds <> rest:
      bench(rd(ks, 1000), rd(ts, 1024), rd(ds, 3))
    case _:
      bench(1000, 1024, 3)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
