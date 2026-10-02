# Stage times of the flat Solver.plan (rows built outside the clock): ingest (sort/normalise/index), column index + buckets, pivot loop,
# post (Pv / leftover lists), phase 2 (coefficient arena, Gauss-Jordan, TC lists).
#   bend tools/scaling/plan_stages.bend -o build/scaling/plan_stages ; taskset -c 10 ./build/scaling/plan_stages --threads 1 -- <K>
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as TB
import ../../src/rfc_funcs.bend as R
import ../../src/solver.bend as S
import ../../src/raptorq.bend as Q
import ../../src/constraints.bend as C

def lp_ck(lp: S.Lp) -> U32:
  match lp:
    case S.Lp{a, nin, jn, done}:
      jn

def mp_ck(m: Maybe<&2, S.Plan>) -> U32:
  match m:
    case None{}:
      0
    case Some{pl}:
      S.Solver.plan_rows(pl)

# stage 1: ingest; returns the Ig
def st1(+l: U32, +p: U32, +n: U32, +t: U32, rows: List<&2, Y.Row>, +nw: U32) -> S.Ig:
  +lim = (l - p : U32)
  S.ig.go(rows, 0, n, l, lim, nw, S.zero_vec(nw), S.Ig{S.ci.perm(U32.to_nat(p), lim, lim, S.f1.cs(n), Array.new(U32, S.clog(S.f1.size(n, l, t)), 0)), Nil{}, S.f1.ct(n, l)})

# stage 2: index + buckets (everything before the loop), returns the array and dn
type S2 is Type:
  S2{a: Array<U32>, dn: List<&2, S.Rw>}

def st2(ig: S.Ig, +n: U32, +l: U32, +t: U32) -> S2:
  match ig:
    case S.Ig{a, dn, cur}:
      +cst = S.f1.cst(n, l)
      +cr = (S.f1.ct(n, l) + t : U32)
      S2{S.be.rows(U32.to_nat(n), 0, n, S.f1.bh(n, l), S.fd.rows(U32.to_nat(n), (n - 1 : U32), n, S.f1.cu(n, l), cr, S.cu.loop(U32.to_nat(l), 0, cst, S.f1.cu(n, l), S.px.fin(S.px.loop(U32.to_nat(l), 1, cst, S.Px{S.pb.rows(U32.to_nat(n), 0, n, cst, a), 0}))))), dn}

def st3(s: S2, +n: U32, +l: U32, +p: U32, +t: U32) -> S.Lp:
  match s:
    case S2{a, dn}:
      S.lp.loop(U32.to_nat(n), n, l, p, (S.f1.ct(n, l) + t : U32), S.Lp{a, 0, 0, 0})

def mk(+sp: TB.SP, +k: U32) -> List<&2, Y.Row>:
  Q.append_rows(C.fixed(sp, 0), C.received_rows(sp, k, Q.rcv_rev(Q.esi_seq(U32.to_nat(k), (k - 1 : U32), []), [])))

def ig_ck(ig: S.Ig) -> U32:
  match ig:
    case S.Ig{a, dn, cur}:
      cur

def s2_ck(s: S2) -> U32:
  match s:
    case S2{a, dn}:
      0

def pk3(lo2: S.Lo2, pvs: List<&2, S.Pv>) -> U32:
  match lo2:
    case S.Lo2{a, rs}:
      U32.from_nat((List.length(&2, S.Pv, pvs) + List.length(&2, S.Rw, rs) : Nat))

def pk2(po: S.Po, +n: U32, +l: U32, +nin: U32) -> U32:
  match po:
    case S.Po{a, pvs}:
      pk3(S.lo.loop(U32.to_nat(n), (n - 1 : U32), n, l, S.Lo2{a, Nil{}}), pvs)

def post_ck(lp: S.Lp, +n: U32, +l: U32) -> U32:
  match lp:
    case S.Lp{a, nin, jn, done}:
      pk2(S.po.loop(U32.to_nat(jn), 0, n, l, S.Po{a, Nil{}}), n, l, nin)

def tm_sum(ts: List<&2, Y.Term>, +acc: U32) -> U32:
  match ts:
    case Nil{}:
      acc
    case Con{h, t}:
      tm_sum(t, (acc + Y.Term.col(h) : U32))

def rows_ck(rs: List<&2, Y.Row>, +acc: U32) -> U32:
  match rs:
    case Nil{}:
      acc
    case Con{r, rest}:
      rows_ck(rest, tm_sum(Y.Row.cols(r), acc))

# stage = how far the pipeline runs: 0 only build + walk the rows, 1 ingest, 2 + column index and buckets, 3 + pivot loop, 4 + post lists, 5 whole plan.
# Every stage builds its own rows inside the clock (stage 0 = the cost to subtract: construction of the terms is lazy).
def run_to(+stage: U32, +n: U32, +l: U32, +p: U32, +t: U32, +k: U32, +sp: TB.SP, +nw: U32) -> U32:
  match stage:
    case 0:
      rows_ck(mk(sp, k), 0)
    case 1:
      ig_ck(st1(l, p, n, t, mk(sp, k), nw))
    case 2:
      s2_ck(st2(st1(l, p, n, t, mk(sp, k), nw), n, l, t))
    case 3:
      lp_ck(st3(st2(st1(l, p, n, t, mk(sp, k), nw), n, l, t), n, l, p, t))
    case 4:
      post_ck(st3(st2(st1(l, p, n, t, mk(sp, k), nw), n, l, t), n, l, p, t), n, l)
    case _:
      mp_ck(S.Solver.plan(l, p, mk(sp, k)))

def go1(+stage: U32, +k: U32, +sp: TB.SP, +n: U32, +t: U32) -> IO(Nat):
  do IO<Nat>:
    +t0 : Nat <- IO.now()
    +c : U32 <- IO.pure(U32, run_to(stage, n, R.L(sp), R.P(sp), t, k, sp, S.nwords(R.L(sp))))
    +t1 : Nat <- IO.now()
    IO.pure(Nat, (t1 - t0 : Nat))

def go(+k: U32) -> IO(Unit):
  do IO<Unit>:
    +sp : TB.SP <- IO.pure(TB.SP, Maybe.default(&2, TB.SP, R.params(k), TB.SP{0, 0, 0, 0, 0, 0}))
    +n : U32 <- IO.pure(U32, U32.from_nat(List.length(&2, Y.Row, mk(sp, k))))
    +t : U32 <- IO.pure(U32, S.f1.tcap(mk(sp, k), 0))
    +z : Nat <- go1(0, k, sp, n, t)
    +a : Nat <- go1(1, k, sp, n, t)
    +b : Nat <- go1(2, k, sp, n, t)
    +c : Nat <- go1(3, k, sp, n, t)
    +d : Nat <- go1(4, k, sp, n, t)
    +e : Nat <- go1(5, k, sp, n, t)
    IO.print("STAGES K=" ++ U32.show(k) ++ " n=" ++ U32.show(n) ++ " t=" ++ U32.show(t) ++ " cum_ms (rows built inside): rows_only=" ++ Nat.show(z) ++ " ingest=" ++ Nat.show(a) ++ " +index/buckets=" ++ Nat.show(b) ++ " +loop=" ++ Nat.show(c) ++ " +post=" ++ Nat.show(d) ++ " whole_plan=" ++ Nat.show(e))

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
