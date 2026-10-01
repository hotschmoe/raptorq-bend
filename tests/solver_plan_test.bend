# Solver.plan (phase 1 on flat arrays) must give the SAME plan as Solver.plan_ref (phase 1 on lists): same pivots in the same order, same
# elimination logs / original terms, same tail rows and tail solution; checked structurally on real RaptorQ systems (encoder systems, and decoder
# systems with repair symbols and with permutations of the received order), including the rank-deficient failures (both None).
#   bend tests/solver_plan_test.bend    (ALL PASS, exit 1 on failure)
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/tables.bend as TB
import ../src/rfc_funcs.bend as R
import ../src/solver.bend as S
import ../src/raptorq.bend as Q
import ../src/constraints.bend as C

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def term_eq(a: List<&2, Y.Term>, b: List<&2, Y.Term>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case Y.Term{c1, f1} <> xs Y.Term{c2, f2} <> ys:
      band(U32.is_eq(c1, c2), band(U32.is_eq(f1, f2), term_eq(xs, ys)))
    case _ _:
      False{}

def log_eq(a: List<&2, S.Lg>, b: List<&2, S.Lg>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case S.Lg{g1, j1} <> xs S.Lg{g2, j2} <> ys:
      band(U32.is_eq(g1, g2), band(U32.is_eq(j1, j2), log_eq(xs, ys)))
    case _ _:
      False{}

def lg_le(a: S.Lg, b: S.Lg) -> Bool:
  match a b:
    case S.Lg{g1, j1} S.Lg{g2, j2}:
      U32.is_le(j1, j2)

# log entries are a sum (their order is irrelevant): compare sorted by pivot number
def log_eqs(a: List<&2, S.Lg>, b: List<&2, S.Lg>) -> Bool:
  log_eq(List.sort(~S.Lg, ~lg_le, a), List.sort(~S.Lg, ~lg_le, b))

def pp_eq(a: List<&2, S.PP>, b: List<&2, S.PP>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case S.PP{i1, pc1, fi1, lg1, oc1} <> xs S.PP{i2, pc2, fi2, lg2, oc2} <> ys:
      band(band(U32.is_eq(i1, i2), U32.is_eq(pc1, pc2)), band(band(U32.is_eq(fi1, fi2), log_eqs(lg1, lg2)), band(term_eq(oc1, oc2), pp_eq(xs, ys))))
    case _ _:
      False{}

def tr_eq(a: List<&2, S.TR>, b: List<&2, S.TR>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case S.TR{i1, lg1} <> xs S.TR{i2, lg2} <> ys:
      band(U32.is_eq(i1, i2), band(log_eqs(lg1, lg2), tr_eq(xs, ys)))
    case _ _:
      False{}

def tc_eq(a: List<&2, S.TC>, b: List<&2, S.TC>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case S.TC{c1, ts1} <> xs S.TC{c2, ts2} <> ys:
      band(U32.is_eq(c1, c2), band(term_eq(ts1, ts2), tc_eq(xs, ys)))
    case _ _:
      False{}

def plan_eq(a: S.Plan, b: S.Plan) -> Bool:
  match a b:
    case S.Plan{l1, n1, np1, nt1, pv1, tr1, tl1} S.Plan{l2, n2, np2, nt2, pv2, tr2, tl2}:
      band(band(U32.is_eq(l1, l2), U32.is_eq(n1, n2)), band(band(U32.is_eq(np1, np2), U32.is_eq(nt1, nt2)), band(pp_eq(pv1, pv2), band(tr_eq(tr1, tr2), tc_eq(tl1, tl2)))))

def mb_eq(a: Maybe<&2, S.Plan>, b: Maybe<&2, S.Plan>) -> Bool:
  match a b:
    case Some{x} Some{y}:
      plan_eq(x, y)
    case None{} None{}:
      True{}
    case _ _:
      False{}

def tag(m: Maybe<&2, S.Plan>) -> String:
  match m:
    case Some{x}:
      " (Some)"
    case None{}:
      " (None)"

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

# the rows of a decoder that receives these ESIs (as Codec.plan_for)
def rows_of(+sp: TB.SP, +k: U32, es: List<&2, U32>) -> List<&2, Y.Row>:
  Q.append_rows(C.fixed(sp, 0), C.received_rows(sp, k, Q.rcv_rev(es, [])))

def esi_rep(n: Nat, +i: U32, +k: U32, +step: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+q:
      esi_rep(q, (i - 1 : U32), k, step, U32.max(0, (k + i * step : U32)) <> acc)

def one(+k: U32, es: List<&2, U32>, name: String) -> IO(U32):
  +sp = Maybe.default(&2, TB.SP, R.params(k), TB.SP{0, 0, 0, 0, 0, 0})
  +e2 = es
  check(mb_eq(S.Solver.plan_ref(R.L(sp), R.P(sp), rows_of(sp, k, e2)), S.Solver.plan(R.L(sp), R.P(sp), rows_of(sp, k, e2))), "flat plan == reference plan: " ++ name ++ " K=" ++ U32.show(k) ++ tag(S.Solver.plan(R.L(sp), R.P(sp), rows_of(sp, k, e2))))

def case_k(+k: U32) -> IO(U32):
  do IO<U32>:
    a : U32 <- one(k, Q.esi_seq(U32.to_nat(k), (k - 1 : U32), []), "encoder system")
    b : U32 <- one(k, esi_rep(U32.to_nat(k), (k - 1 : U32), k, 1, []), "all repair, consecutive")
    c : U32 <- one(k, esi_rep(U32.to_nat((k + 3 : U32)), (k + 2 : U32), k, 7, []), "repair, stride 7, 3 extra")
    d : U32 <- one(k, esi_rep(U32.to_nat((k / 2 + 3 : U32)), (k / 2 + 2 : U32), 0, 2, Q.esi_seq(U32.to_nat((k - k / 2 : U32)), (k - k / 2 - 1 : U32), [])), "mixed source / repair, 3 extra")
    IO.pure(U32, (a + b + c + d : U32))

def fin(+n: U32) -> IO(Unit):
  match n:
    case 0:
      IO.print("ALL PASS")
    case _:
      IO.die(Unit, 1, "FAILURES: " ++ U32.show(n))

def main() -> IO(Unit):
  do IO<Unit>:
    a : U32 <- case_k(10)
    b : U32 <- case_k(26)
    c : U32 <- case_k(100)
    d : U32 <- case_k(500)
    e : U32 <- case_k(1000)
    fin((a + b + c + d + e : U32))
