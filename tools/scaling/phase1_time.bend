# Phase-1 split of the encoder system: row construction, init (normalise + index), phase-1 loop.
#   bend tools/scaling/phase1_time.bend -o build/scaling/phase1_time ; taskset -c 10 ./build/scaling/phase1_time --threads 1 -- <K>
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as TB
import ../../src/rfc_funcs.bend as R
import ../../src/solver.bend as S
import ../../src/raptorq.bend as Q
import ../../src/constraints.bend as C

def pl_n(pv: S.Pl) -> U32:
  match pv:
    case S.Pl{n, l, nin, il, p}:
      n

def p1_ck(st: S.P1) -> U32:
  match st:
    case S.P1{rows, wt, bk, ci, dn, pivs, done}:
      pl_n(pivs)

def go(+k: U32, +rows: List<&2, Y.Row>, +l: U32, +p: U32, +nw: U32) -> IO(Unit):
  do IO<Unit>:
    +n : U32 <- IO.pure(U32, U32.from_nat(List.length(&2, Y.Row, rows)))
    +t0 : Nat <- IO.now()
    +c1 : U32 <- IO.pure(U32, p1_ck(S.p1_of(S.init_go(rows, l, p, S.zero_vec(nw), nw, 0, S.in_new(n, l)), p)))
    +t1 : Nat <- IO.now()
    +c2 : U32 <- IO.pure(U32, p1_ck(S.phase1(l, p, n, rows, nw)))
    +t2 : Nat <- IO.now()
    IO.print("PHASE1 K=" ++ U32.show(k) ++ " init_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " init+loop_ms=" ++ Nat.show((t2 - t1 : Nat)) ++ " pivots=" ++ U32.show(c2))

def bench(+k: U32) -> IO(Unit):
  do IO<Unit>:
    +sp : TB.SP <- IO.pure(TB.SP, Maybe.default(&2, TB.SP, R.params(k), TB.SP{0, 0, 0, 0, 0, 0}))
    +rows : List<&2, Y.Row> <- IO.pure(List<&2, Y.Row>, Q.append_rows(C.fixed(sp, 0), C.received_rows(sp, k, Q.rcv_rev(Q.esi_seq(U32.to_nat(k), (k - 1 : U32), []), []))))
    +n : U32 <- IO.pure(U32, U32.from_nat(List.length(&2, Y.Row, rows)))
    go(k, rows, R.L(sp), R.P(sp), S.nwords(R.L(sp)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> rest:
      bench(rd(ks, 1000))
    case _:
      bench(1000)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
