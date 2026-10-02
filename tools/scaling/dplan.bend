# Plan time of the DECODER system (K symbols received, 7/8 of them repair: tools/bench pattern) vs the encoder system.
#   bend tools/scaling/dplan.bend -o build/scaling/dplan ; taskset -c 0 ./build/scaling/dplan --threads 1 -- <K>
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

def pick(b: Bool, +i: U32, +k: U32) -> U32:
  match b:
    case True{}:
      i
    case False{}:
      (k + i : U32)

def esis(n: Nat, +i: U32, +k: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      esis(p, (i - 1 : U32), k, pick(U32.is_eq((i .&. 7 : U32), 0), i, k) <> acc)

def go(+k: U32) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +c0 : U32 <- IO.pure(U32, pl_ck(Q.Codec.encoder_plan(k)))
    +t1 : Nat <- IO.now()
    +c1 : U32 <- IO.pure(U32, pl_ck(Q.Codec.plan_for(k, esis(U32.to_nat(k), (k - 1 : U32), k, []))))
    +t2 : Nat <- IO.now()
    IO.print("DPLAN K=" ++ U32.show(k) ++ " encoder_plan_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " decoder_plan_ms=" ++ Nat.show((t2 - t1 : Nat)) ++ " ok=" ++ U32.show(c0) ++ "/" ++ U32.show(c1))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> rest:
      go(rd(ks, 1000))
    case _:
      go(1000)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
