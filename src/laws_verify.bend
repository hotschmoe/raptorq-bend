# Equation checking for the solver (docs/proofs.md): `verify` evaluates every row equation
#   sum_i coef_i * C[col_i] == rhs
# on a candidate solution, and `Solver.solve_checked` / `decode_checked` return Some only
# when it holds.  Nothing in the codec depends on this file; it is the executable half of laws
# `verify_sound` and `solve_checked_sound` (LAWS.bend).
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./solver.bend as S
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./constraints.bend as C
import ./raptorq.bend as Q

# Structural equality of symbols (shape and every word).
def Vec.eq(a: G.Vec, b: G.Vec) -> Bool:
  match a b:
    case G.VNil{} G.VNil{}:
      True{}
    case G.VWord{x} G.VWord{y}:
      U32.is_eq(x, y)
    case G.VNode{al, ar} G.VNode{bl, br}:
      Bool.and(Vec.eq(al, bl), Vec.eq(ar, br))
    case _ _:
      False{}

# C[i] (the i-th symbol), VNil when out of range.
def nth(xs: List<&2, G.Vec>, +i: U32) -> G.Vec:
  match xs:
    case Nil{}:
      G.VNil{}
    case Con{h, t}:
      match i:
        case 0:
          h
        case _:
          nth(t, (i - 1 : U32))

def eval.go(ts: List<&2, Y.Term>, +sol: List<&2, G.Vec>, acc: G.Vec) -> G.Vec:
  match ts:
    case Nil{}:
      acc
    case Con{t, rest}:
      match t:
        case Y.Term{col, coef}:
          eval.go(rest, sol, G.Vec.muladd(coef, acc, nth(sol, col)))

# sum of coef * C[col] over the row's terms, starting from the zero symbol of the rhs's shape
def Row.eval(r: Y.Row, +sol: List<&2, G.Vec>) -> G.Vec:
  match r:
    case Y.Row{cols, +rhs}:
      eval.go(cols, sol, G.Vec.zeros(rhs))

def Row.rhs(r: Y.Row) -> G.Vec:
  match r:
    case Y.Row{cols, rhs}:
      rhs

def Row.holds(+r: Y.Row, +sol: List<&2, G.Vec>) -> Bool:
  Vec.eq(Row.eval(r, sol), Row.rhs(r))

# every row equation holds (as a Bool)
def verify(rows: List<&2, Y.Row>, +sol: List<&2, G.Vec>) -> Bool:
  match rows:
    case Nil{}:
      True{}
    case Con{r, rest}:
      Bool.and(Row.holds(r, sol), verify(rest, sol))

# every row equation holds (as a proposition)
def Sat(rows: List<&2, Y.Row>, +sol: List<&2, G.Vec>) -> Type:
  match rows:
    case Nil{}:
      Unit
    case Con{r, rest}:
      {Row.eval(r, sol) == Row.rhs(r) : G.Vec} & Sat(rest, sol)

def sc.pick(sol: List<&2, G.Vec>, ok: Bool) -> Maybe<&2, List<&2, G.Vec>>:
  match ok:
    case True{}:
      Some{sol}
    case False{}:
      None{}

def sc.go(m: Maybe<&2, List<&2, G.Vec>>, +rows: List<&2, Y.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      None{}
    case Some{+sol}:
      sc.pick(sol, verify(rows, sol))

# Solver.solve_p, but Some(sol) only if sol satisfies every row (verified, not assumed).
def Solver.solve_checked(+l: U32, +p: U32, +rows: List<&2, Y.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  sc.go(S.Solver.solve_p(l, p, rows), rows)

# ---------------------------------------------------------------------------
# Codec.decode with the verified solver: same pipeline as Q.Codec.decode (src/raptorq.bend), but the
# intermediate symbols must satisfy every received equation, the S+H constraint rows and the K'-K padding
# rows.  Plain Codec.decode accepts an overdetermined system with a corrupted symbol (the solver only
# needs a full-rank subset); decode_checked returns None instead.
# ---------------------------------------------------------------------------

def dc.solve(m: Maybe<&2, T.SP>, enough: Bool, +k: U32, +t: U32, rv: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match enough:
        case False{}:
          None{}
        case True{}:
          Q.dec.fin(Solver.solve_checked(R.L(sp), R.P(sp), Q.append_rows(C.fixed(sp, t), C.received_rows(sp, k, rv))), k, sp)

def Codec.decode_checked(+k: U32, +t: U32, received: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  +rv = received
  dc.solve(R.params(k), Q.band(U32.is_ge(Q.len_rcv(rv, 0), k), Q.band(U32.is_gt(k, 0), U32.is_gt(t, 0))), k, t, rv)
