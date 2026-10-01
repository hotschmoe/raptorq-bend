# A/B of Solver.plan_ref (phase 1 on lists) vs Solver.plan (phase 1 on flat arrays) on the encoder system of K source symbols.
#   bend tools/scaling/plan_ab.bend -o build/scaling/plan_ab ; taskset -c 10 ./build/scaling/plan_ab --threads 1 -- <K> <reps>
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as TB
import ../../src/rfc_funcs.bend as R
import ../../src/solver.bend as S
import ../../src/raptorq.bend as Q
import ../../src/constraints.bend as C

def pl_ck(m: Maybe<&2, S.Plan>) -> U32:
  match m:
    case None{}:
      0
    case Some{pl}:
      S.Solver.plan_rows(pl)

def mk(+sp: TB.SP, +k: U32) -> List<&2, Y.Row>:
  Q.append_rows(C.fixed(sp, 0), C.received_rows(sp, k, Q.rcv_rev(Q.esi_seq(U32.to_nat(k), (k - 1 : U32), []), [])))

def one(+n: Nat, +l: U32, +p: U32, +k: U32, +sp: TB.SP) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+q:
      do IO<Unit>:
        +t0 : Nat <- IO.now()
        +c1 : U32 <- IO.pure(U32, pl_ck(S.Solver.plan_ref(l, p, mk(sp, k))))
        +t1 : Nat <- IO.now()
        +c2 : U32 <- IO.pure(U32, pl_ck(S.Solver.plan(l, p, mk(sp, k))))
        +t2 : Nat <- IO.now()
        IO.print("PLAN ref_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " flat_ms=" ++ Nat.show((t2 - t1 : Nat)) ++ " rows=" ++ U32.show(c1) ++ "/" ++ U32.show(c2) ++ " (rows built inside both)")
        one(q, l, p, k, sp)

def go(+k: U32, +reps: U32) -> IO(Unit):
  do IO<Unit>:
    +sp : TB.SP <- IO.pure(TB.SP, Maybe.default(&2, TB.SP, R.params(k), TB.SP{0, 0, 0, 0, 0, 0}))
    one(U32.to_nat(reps), R.L(sp), R.P(sp), k, sp)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> rs <> rest:
      go(rd(ks, 1000), rd(rs, 3))
    case _:
      go(1000, 3)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
