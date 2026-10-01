# Stage timings of Solver.apply on the arena for the encoder system (plan once, then: rhs list, apply_arena, read-out as Vecs).
#   bend tools/profile/bench_apply.bend -o build/bench_apply ; taskset -c 11 ./build/bench_apply --threads 1 -- <K> <T>
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as T
import ../../src/rfc_funcs.bend as R
import ../../src/flat.bend as F
import ../../src/solver.bend as S
import ../../src/raptorq.bend as Q
import ../../src/constraints.bend as C

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

def head_sum(xs: List<&2, G.Vec>) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{v, _}:
      fold_words(G.Vec.to_list(v, Nil{}), 0)

def len_of(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len_of(t, (acc + 1 : U32))

def ck.fin(r: Array<U32> & U32) -> U32:
  (a, x) = r
  x

# one slot of the arena (forces the whole replay: the array is threaded through every loop)
def ar_ck(ar: F.Ar) -> U32:
  match ar:
    case F.Ar{a, wu, ca, sc}:
      ck.fin(Array.get(U32, a, sc))

def go(m: Maybe<&2, S.Plan>, +sp: T.SP, +k: U32, +t: U32, +src: List<&2, G.Vec>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "None")
    case Some{+plan}:
      do IO<Unit>:
        +t0 : Nat <- IO.now()
        +rhs : List<&2, G.Vec> <- IO.pure(List<&2, G.Vec>, Q.wp.rhs(sp, k, t, src))
        IO.print("rhs rows " ++ U32.show(len_of(rhs, 0)))
        +t1 : Nat <- IO.now()
        +c1 : U32 <- IO.pure(U32, ar_ck(S.Solver.apply_arena(plan, rhs)))
        IO.print("arena checksum " ++ U32.show(c1))
        +t2 : Nat <- IO.now()
        +rhs2 : List<&2, G.Vec> <- IO.pure(List<&2, G.Vec>, Q.wp.rhs(sp, k, t, src))
        +res : List<&2, G.Vec> <- IO.pure(List<&2, G.Vec>, S.Solver.apply(plan, rhs2))
        IO.print("apply head " ++ U32.show(head_sum(res)))
        +t3 : Nat <- IO.now()
        IO.print("RESULT K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " rhs_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " apply_arena_ms=" ++ Nat.show((t2 - t1 : Nat)) ++ " rhs+apply+readout_ms=" ++ Nat.show((t3 - t2 : Nat)))

def bench(+k: U32, +t: U32) -> IO(Unit):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<Unit>:
    +sp0 : T.SP <- IO.pure(T.SP, Maybe.default(&2, T.SP, R.params(k), T.SP{0, 0, 0, 0, 0, 0}))
    +rows : List<&2, Y.Row> <- IO.pure(List<&2, Y.Row>, Q.append_rows(C.fixed(sp0, 0), C.received_rows(sp0, k, Q.rcv_rev(Q.esi_seq(U32.to_nat(k), (k - 1 : U32), []), []))))
    IO.print("rows built " ++ Nat.show(List.length(&2, Y.Row, rows)))
    +ta : Nat <- IO.now()
    IO.print("inactive_count " ++ U32.show(S.Solver.inactive_count(R.L(sp0), R.P(sp0), rows)))
    +tb : Nat <- IO.now()
    IO.print("phase1_ms=" ++ Nat.show((tb - ta : Nat)))
    +t0 : Nat <- IO.now()
    +pm : Maybe<&2, S.Plan> <- IO.pure(Maybe<&2, S.Plan>, Q.Codec.encoder_plan(k))
    IO.print("plan ok")
    +t1 : Nat <- IO.now()
    IO.print("plan_ms=" ++ Nat.show((t1 - t0 : Nat)))
    go(pm, Maybe.default(&2, T.SP, R.params(k), T.SP{0, 0, 0, 0, 0, 0}), k, t, src)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ts <> rest:
      bench(rd(ks, 1000), rd(ts, 1024))
    case _:
      bench(1000, 1024)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
