# Linear-system solver over GF(256) -- RFC 6330 section 5.4.2 (inactivation decoding).
#
#   Solver.solve(l, rows)        -> Maybe<List<Sym>>   (inactivation decoding; default entry point)
#   Solver.solve_p(l, p, rows)   -> same, with p = number of permanently inactive columns
#                                   (the LAST p columns, RFC P = L - W); solve = solve_p(l, 0, ..)
#   Solver.solve_dense(l, rows)  -> same answer by plain Gauss-Jordan (test oracle)
#
# See docs/solver.md for the design. Overview:
#   phase 1  sparse rows are eliminated by min-weight pivoting; the other active columns of the
#            chosen row are INACTIVATED (moved into a small "inactive" part of every row), so the
#            active part never fills in.  Dense rows (HDPC-like) are kept as packed coefficient Vecs.
#   phase 2  the leftover rows over the inactive columns are solved by dense Gauss-Jordan.
#   phase 3  every pivot row is back-substituted from the inactive solution (independent => parallel).
# Every per-step pass over the rows is a divide-and-conquer map/reduce over a balanced tree (parallel).
import Base
import ./gf256.bend as G
import ./types.bend as T

# ===========================================================================
# 1. Small helpers
# ===========================================================================

# Bool -> all-ones / zero mask
def b2m(b: Bool) -> U32:
  match b:
    case True{}:
      4294967295
    case False{}:
      0

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

# octet j (0..3) of a packed word (big-endian inside the word, see docs/gf256.md)
def byte_of(w: U32, j: U32) -> U32:
  match j:
    case 0:
      U32.shrn(w, 24n)
    case 1:
      U32.and(U32.shrn(w, 16n), 255)
    case 2:
      U32.and(U32.shrn(w, 8n), 255)
    case _:
      U32.and(w, 255)

# octet a placed in lane j of an otherwise zero word
def byte_word(a: U32, j: U32) -> U32:
  match j:
    case 0:
      U32.shln(a, 24n)
    case 1:
      U32.shln(a, 16n)
    case 2:
      U32.shln(a, 8n)
    case _:
      a

# ---------------------------------------------------------------------------
# O(log n) point access into a packed Vec.  n = number of words of v.  The shape of a Vec built
# by Vec.from_list is: split n words into h = n/2 (left) and n-h (right).  The two recursive calls
# are guarded by a `live` mask so only one of them goes down.
# ---------------------------------------------------------------------------
def vget_word(+d: Nat, +live: U32, v: G.Vec, +i: U32, +n: U32) -> U32:
  match d:
    case 0n:
      0
    case 1n+p:
      match live:
        case 0:
          0
        case _:
          match v:
            case G.VNode{l, r}:
              +h = U32.shr(n)
              +m = b2m(U32.is_lt(i, h))
              a = vget_word(p, (live .&. m : U32), l, i, h)
              b = vget_word(p, (live .&. (m .^. 4294967295 : U32) : U32), r, (i - h : U32), (n - h : U32))
              (a .|. b : U32)
            case G.VWord{w}:
              w
            case G.VNil{}:
              0

# v[word i] ^= x
def vxor_word(+d: Nat, +x: U32, v: G.Vec, +i: U32, +n: U32) -> G.Vec:
  match d:
    case 0n:
      v
    case 1n+p:
      match x:
        case 0:
          v
        case _:
          match v:
            case G.VNode{l, r}:
              +h = U32.shr(n)
              +m = b2m(U32.is_lt(i, h))
              a = vxor_word(p, (x .&. m : U32), l, i, h)
              b = vxor_word(p, (x .&. (m .^. 4294967295 : U32) : U32), r, (i - h : U32), (n - h : U32))
              G.VNode{a, b}
            case G.VWord{w}:
              G.VWord{(w .^. x : U32)}
            case G.VNil{}:
              G.VNil{}

# octet number c of the coefficient vector v (nw words)
def vget_oct(v: G.Vec, +c: U32, +nw: U32) -> U32:
  byte_of(vget_word(32n, 1, v, U32.shrn(c, 2n), nw), U32.and(c, 3))

# v[octet c] ^= a
def vxor_oct(v: G.Vec, +c: U32, +nw: U32, a: U32) -> G.Vec:
  vxor_word(32n, byte_word(a, U32.and(c, 3)), v, U32.shrn(c, 2n), nw)

def nwords(n: U32) -> U32:
  U32.shrn((n + 3 : U32), 2n)

def zero_vec(nw: U32) -> G.Vec:
  G.Vec.from_list(List.replicate(U32, U32.to_nat(nw), 0))

# ===========================================================================
# 2. Dense Gauss-Jordan (phase 2, and the standalone oracle)
#    Rows are packed coefficient vectors + RHS symbols in a balanced tree; each step is one
#    parallel pass: eliminate column c from every row AND find the pivot candidate for column c+1.
# ===========================================================================

type DG is Data:
  DG{id: U32, piv: U32, co: G.Vec, rhs: G.Vec}      # piv = pivot column + 1, or 0 if not a pivot row yet

type DT is Data:
  DTNil{}
  DTLeaf{r: DG}
  DTNode{l: DT, r: DT}

type Cand is Data:
  CNone{}
  CSome{r: DG}

type DP is Data:
  DP{t: DT, c: Cand}

type Pr is Data:
  Pr{k: U32, v: G.Vec}

def dt_node(l: DT, r: DT) -> DT:
  match l r:
    case DTNil{} DTNil{}:
      DTNil{}
    case a b:
      DTNode{a, b}

def cand_or(a: Cand, b: Cand) -> Cand:
  match a:
    case CNone{}:
      b
    case CSome{r}:
      CSome{r}

def dg_cand(b: Bool, r: DG) -> Cand:
  match b:
    case True{}:
      CSome{r}
    case False{}:
      CNone{}

def dp_join(a: DP, b: DP) -> DP:
  match a b:
    case DP{ta, ca} DP{tb, cb}:
      DP{dt_node(ta, tb), cand_or(ca, cb)}

def dg_leaf.go(isp: Bool, id: U32, +piv: U32, +co: G.Vec, rhs: G.Vec, +c: U32, +nw: U32, +nc: U32, pco: G.Vec, prhs: G.Vec) -> DP:
  match isp:
    case True{}:
      DP{DTLeaf{DG{id, (c + 1 : U32), pco, prhs}}, CNone{}}
    case False{}:
      +f = vget_oct(co, c, nw)
      +co2 = G.Vec.muladd(f, co, pco)
      +r2 = {DG{id, piv, co2, G.Vec.muladd(f, rhs, prhs)} : DG}
      +ok = band(U32.is_eq(piv, 0), U32.is_ne(vget_oct(co2, nc, nw), 0))
      DP{DTLeaf{r2}, dg_cand(ok, r2)}

def dg_leaf(r: DG, c: U32, nw: U32, nc: U32, pco: G.Vec, prhs: G.Vec, pid: U32) -> DP:
  match r:
    case DG{+id, piv, co, rhs}:
      dg_leaf.go(U32.is_eq(id, pid), id, piv, co, rhs, c, nw, nc, pco, prhs)

def dg_pass(t: DT, +c: U32, +nw: U32, +nc: U32, +pco: G.Vec, +prhs: G.Vec, +pid: U32) -> DP:
  match t:
    case DTNil{}:
      DP{DTNil{}, CNone{}}
    case DTLeaf{r}:
      dg_leaf(r, c, nw, nc, pco, prhs, pid)
    case DTNode{l, r}:
      a b = dg_pass(l, c, nw, nc, pco, prhs, pid) dg_pass(r, c, nw, nc, pco, prhs, pid)
      dp_join(a, b)

# first row (in tree order) that is not yet a pivot and has a nonzero entry in column c
def dg_find(t: DT, +c: U32, +nw: U32) -> Cand:
  match t:
    case DTNil{}:
      CNone{}
    case DTLeaf{r}:
      match r:
        case DG{+id, +piv, +co, rhs}:
          dg_cand(band(U32.is_eq(piv, 0), U32.is_ne(vget_oct(co, c, nw), 0)), DG{id, piv, co, rhs})
    case DTNode{l, r}:
      a b = dg_find(l, c, nw) dg_find(r, c, nw)
      cand_or(a, b)

def dg_collect.go(z: Bool, piv: U32, rhs: G.Vec, acc: List<&2, Pr>) -> List<&2, Pr>:
  match z:
    case True{}:
      acc
    case False{}:
      Pr{(piv - 1 : U32), rhs} <> acc

# pivot rows -> (column, solution symbol)
def dg_collect(t: DT, acc: List<&2, Pr>) -> List<&2, Pr>:
  match t:
    case DTNil{}:
      acc
    case DTLeaf{r}:
      match r:
        case DG{id, +piv, co, rhs}:
          dg_collect.go(U32.is_eq(piv, 0), piv, rhs, acc)
    case DTNode{l, r}:
      dg_collect(l, dg_collect(r, acc))

# fuel k = number of columns still to process; c = current column; n = number of columns.
# st = (tree, pivot candidate for column c).  Returns the pivot solutions, or None if rank < n.
def dg_loop(k: Nat, st: DP, +c: U32, +n: U32, +nw: U32) -> Maybe<&2, List<&2, Pr>>:
  match k:
    case 0n:
      match st:
        case DP{t, cand}:
          Some{dg_collect(t, Nil{})}
    case 1n+p:
      match st:
        case DP{t, cand}:
          match cand:
            case CNone{}:
              None{}
            case CSome{r}:
              match r:
                case DG{id, piv, +co, rhs}:
                  +iv = G.inv(vget_oct(co, c, nw))
                  +pco = G.Vec.scale(iv, co)
                  +prhs = G.Vec.scale(iv, rhs)
                  nc = U32.min((c + 1 : U32), (n - 1 : U32))
                  dg_loop(p, dg_pass(t, c, nw, nc, pco, prhs, id), (c + 1 : U32), n, nw)

def dg_run(+t: DT, +n: U32, +nw: U32) -> Maybe<&2, List<&2, Pr>>:
  dg_loop(U32.to_nat(n), DP{t, dg_find(t, 0, nw)}, 0, n, nw)

# ===========================================================================
# 3. Index trees: unordered (index, symbol) pairs -> symbols ordered by index, and O(log n) lookup
# ===========================================================================

type ST is Data:
  SE{}
  SL{v: G.Vec}
  SN{l: ST, r: ST}

def bnot(a: Bool) -> Bool:
  match a:
    case True{}:
      False{}
    case False{}:
      True{}

def beq(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      bnot(b)

def flt.step(keep: Bool, x: Pr, acc: List<&2, Pr>) -> List<&2, Pr>:
  match keep:
    case True{}:
      x <> acc
    case False{}:
      acc

# pairs with k < mid (lowside True) or k >= mid (lowside False); order not preserved
def flt(xs: List<&2, Pr>, +mid: U32, +lowside: Bool, acc: List<&2, Pr>) -> List<&2, Pr>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case Pr{+k, v}:
          flt(t, mid, lowside, flt.step(beq(U32.is_lt(k, mid), lowside), Pr{k, v}, acc))

def st_leaf(xs: List<&2, Pr>) -> ST:
  match xs:
    case Nil{}:
      SE{}
    case h <> t:
      match h:
        case Pr{k, v}:
          SL{v}

# xs: pairs whose k lies in [lo, lo+w); fuel d bounds the depth
def st_build(+d: Nat, +w: U32, +lo: U32, +xs: List<&2, Pr>) -> ST:
  match d:
    case 0n:
      SE{}
    case 1n+p:
      match w:
        case 0:
          SE{}
        case 1:
          st_leaf(xs)
        case _:
          +h = U32.shr(w)
          +mid = (lo + h : U32)
          l r = st_build(p, h, lo, flt(xs, mid, True{}, Nil{})) st_build(p, (w - h : U32), mid, flt(xs, mid, False{}, Nil{}))
          SN{l, r}

def st_pick(b: Bool, l: ST, r: ST) -> ST:
  match b:
    case True{}:
      l
    case False{}:
      r

def pick_u(b: Bool, x: U32, y: U32) -> U32:
  match b:
    case True{}:
      x
    case False{}:
      y

def st_get(+d: Nat, t: ST, +lo: U32, +w: U32, +k: U32) -> G.Vec:
  match d:
    case 0n:
      G.VNil{}
    case 1n+p:
      match t:
        case SE{}:
          G.VNil{}
        case SL{v}:
          v
        case SN{l, r}:
          +h = U32.shr(w)
          +left = U32.is_lt(k, (lo + h : U32))
          st_get(p, st_pick(left, l, r), pick_u(left, lo, (lo + h : U32)), pick_u(left, h, (w - h : U32)), k)

def st_to_list(t: ST, acc: List<G.Vec>) -> List<G.Vec>:
  match t:
    case SE{}:
      acc
    case SL{v}:
      v <> acc
    case SN{l, r}:
      st_to_list(l, st_to_list(r, acc))

# ===========================================================================
# 4. Row trees
# ===========================================================================

def dt_pair(xs: List<&2, DT>, acc: List<&2, DT>) -> List<&2, DT>:
  match xs:
    case Nil{}:
      List.reverse(&2, DT, acc)
    case a <> rest:
      match rest:
        case Nil{}:
          List.reverse(&2, DT, a <> acc)
        case b <> r2:
          dt_pair(r2, dt_node(a, b) <> acc)

def dt_build(+d: Nat, xs: List<&2, DT>) -> DT:
  match d:
    case 0n:
      DTNil{}
    case 1n+p:
      match xs:
        case Nil{}:
          DTNil{}
        case a <> Nil{}:
          a
        case a <> b <> rest:
          dt_build(p, dt_pair(a <> b <> rest, Nil{}))

# sum(coef * C[col]) into a dense coefficient vector of nw words
def fold_terms(ts: List<&2, T.Term>, co: G.Vec, +nw: U32) -> G.Vec:
  match ts:
    case Nil{}:
      co
    case h <> t:
      match h:
        case T.Term{col, coef}:
          fold_terms(t, vxor_oct(co, col, nw, coef), nw)

def row_dg(+zero: G.Vec, +nw: U32, id: U32, r: T.Row) -> DG:
  match r:
    case T.Row{cols, rhs}:
      DG{id, 0, fold_terms(cols, zero, nw), rhs}

def dg_rows(rows: List<T.Row>, +zero: G.Vec, +nw: U32, +id: U32, acc: List<&2, DT>) -> List<&2, DT>:
  match rows:
    case Nil{}:
      List.reverse(&2, DT, acc)
    case r <> rest:
      dg_rows(rest, zero, nw, (id + 1 : U32), DTLeaf{row_dg(zero, nw, id, r)} <> acc)

# pivot pairs (index = column) -> the solution list C[0..n-1]
def dense_fin(res: Maybe<&2, List<&2, Pr>>, +n: U32) -> Maybe<List<G.Vec>>:
  match res:
    case None{}:
      None{}
    case Some{ps}:
      Some{st_to_list(st_build(32n, n, 0, ps), Nil{})}

# Plain Gauss-Jordan over the whole system (test oracle).
def Solver.solve_dense(+l: U32, rows: List<T.Row>) -> Maybe<List<G.Vec>>:
  +nw = nwords(l)
  dense_fin(dg_run(dt_build(32n, dg_rows(rows, zero_vec(nw), nw, 0, Nil{})), l, nw), l)

# ===========================================================================
# 5. Sparse term lists (sorted by column)
# ===========================================================================

def term_le(a: T.Term, b: T.Term) -> Bool:
  match a b:
    case T.Term{ca, fa} T.Term{cb, fb}:
      U32.is_le(ca, cb)

def u32_le(a: U32, b: U32) -> Bool:
  U32.is_le(a, b)

def pick_l(b: Bool, x: List<&2, U32>, y: List<&2, U32>) -> List<&2, U32>:
  match b:
    case True{}:
      x
    case False{}:
      y

# a * g (coefficient-wise)
def tscale(ys: List<&2, T.Term>, +g: U32) -> List<&2, T.Term>:
  match ys:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case T.Term{c, f}:
          T.Term{c, G.mul(g, f)} <> tscale(t, g)

# state of a sorted merge: reversed output, remaining left, remaining right
type Mg is Data:
  Mg{acc: List<&2, T.Term>, xs: List<&2, T.Term>, ys: List<&2, T.Term>}

def mg_zero(z: Bool, c: U32, s: U32, xt: List<&2, T.Term>, yt: List<&2, T.Term>, acc: List<&2, T.Term>) -> Mg:
  match z:
    case True{}:
      Mg{acc, xt, yt}
    case False{}:
      Mg{T.Term{c, s} <> acc, xt, yt}

def mg_step(k: Cmp, +g: U32, +xc: U32, +xf: U32, xt: List<&2, T.Term>, +yc: U32, +yf: U32, yt: List<&2, T.Term>, acc: List<&2, T.Term>) -> Mg:
  match k:
    case LT{}:
      Mg{T.Term{xc, xf} <> acc, xt, T.Term{yc, yf} <> yt}
    case GT{}:
      Mg{T.Term{yc, G.mul(g, yf)} <> acc, T.Term{xc, xf} <> xt, yt}
    case EQ{}:
      +s = (xf .^. G.mul(g, yf) : U32)
      mg_zero(U32.is_eq(s, 0), xc, s, xt, yt, acc)

def mg_pair(+g: U32, x: T.Term, xt: List<&2, T.Term>, y: T.Term, yt: List<&2, T.Term>, acc: List<&2, T.Term>) -> Mg:
  match x y:
    case T.Term{+xc, xf} T.Term{+yc, yf}:
      mg_step(U32.cmp(xc, yc), g, xc, xf, xt, yc, yf, yt, acc)

def mg_go(f: Nat, +g: U32, st: Mg) -> List<&2, T.Term>:
  match f:
    case 0n:
      match st:
        case Mg{acc, xs, ys}:
          List.reverse(&2, T.Term, acc)
    case 1n+q:
      match st:
        case Mg{acc, xs, ys}:
          match xs ys:
            case Nil{} Nil{}:
              List.reverse(&2, T.Term, acc)
            case Nil{} y <> yt:
              List.reverse.go(&2, T.Term, acc, tscale(y <> yt, g))
            case x <> xt Nil{}:
              List.reverse.go(&2, T.Term, acc, x <> xt)
            case x <> xt y <> yt:
              mg_go(q, g, mg_pair(g, x, xt, y, yt, acc))

# a + g*b over GF(256): both sorted by column; result sorted, without zero coefficients
def tmerge(+g: U32, +a: List<&2, T.Term>, +b: List<&2, T.Term>) -> List<&2, T.Term>:
  match b:
    case Nil{}:
      a
    case _:
      mg_go(List.length(&2, T.Term, List.append(&2, T.Term, a, b)), g, Mg{Nil{}, a, b})

# ---- row normalisation: sort by column, XOR duplicate columns, drop zeros ------------------
def tn_zero(z: Bool, c: U32, f: U32, acc: List<&2, T.Term>) -> List<&2, T.Term>:
  match z:
    case True{}:
      acc
    case False{}:
      T.Term{c, f} <> acc

def tn_push.go(same: Bool, +ac: U32, +af: U32, c: U32, +f: U32, at: List<&2, T.Term>) -> List<&2, T.Term>:
  match same:
    case True{}:
      tn_zero(U32.is_eq((af .^. f : U32), 0), ac, (af .^. f : U32), at)
    case False{}:
      tn_zero(U32.is_eq(f, 0), c, f, T.Term{ac, af} <> at)

def tn_push(acc: List<&2, T.Term>, +c: U32, +f: U32) -> List<&2, T.Term>:
  match acc:
    case Nil{}:
      tn_zero(U32.is_eq(f, 0), c, f, Nil{})
    case a <> at:
      match a:
        case T.Term{+ac, af}:
          tn_push.go(U32.is_eq(ac, c), ac, af, c, f, at)

def tnorm(ts: List<&2, T.Term>, acc: List<&2, T.Term>) -> List<&2, T.Term>:
  match ts:
    case Nil{}:
      List.reverse(&2, T.Term, acc)
    case h <> t:
      match h:
        case T.Term{c, f}:
          tnorm(t, tn_push(acc, c, f))

def tsort(ts: List<&2, T.Term>) -> List<&2, T.Term>:
  tnorm(List.sort(~T.Term, ~term_le, ts), Nil{})

def ts_flt.step(keep: Bool, c: U32, f: U32, acc: List<&2, T.Term>) -> List<&2, T.Term>:
  match keep:
    case True{}:
      T.Term{c, f} <> acc
    case False{}:
      acc

# terms with col < lim (lowside) or col >= lim; order not preserved
def ts_flt(ts: List<&2, T.Term>, +lim: U32, +lowside: Bool, acc: List<&2, T.Term>) -> List<&2, T.Term>:
  match ts:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case T.Term{+c, f}:
          ts_flt(t, lim, lowside, ts_flt.step(beq(U32.is_lt(c, lim), lowside), c, f, acc))

# ===========================================================================
# 6. Phase 1: sparse elimination with inactivation
# ===========================================================================
# Sp = sparse row: act = terms in ACTIVE columns, ina = terms in INACTIVE columns (both sorted), w = |act|.
# Dn = dense row: coefficient Vec over all l columns (HDPC-like rows); never chosen as a pivot.
type Rw is Data:
  Sp{id: U32, w: U32, act: List<&2, T.Term>, ina: List<&2, T.Term>, rhs: G.Vec}
  Dn{id: U32, co: G.Vec, rhs: G.Vec}

type RT is Data:
  RNil{}
  RLeaf{r: Rw}
  RNode{l: RT, r: RT}

# One elimination step: pivot column pc (coefficient pcf in the pivot row), columns s are inactivated,
# pina/prhs = the pivot row's inactive part and rhs, pid = pivot row id (removed from the tree).
type Stp is Data:
  Stp{pc: U32, pcf: U32, s: List<&2, U32>, pina: List<&2, T.Term>, prhs: G.Vec, pid: U32}

type Pv is Data:
  Pv{pc: U32, pcf: U32, pina: List<&2, T.Term>, rhs: G.Vec}

type RP is Data:
  RP{t: RT, best: Rw}

type Ph is Data:
  Ph{t: RT, best: Rw, pivs: List<&2, Pv>}

def rt_node(l: RT, r: RT) -> RT:
  match l r:
    case RNil{} RNil{}:
      RNil{}
    case a b:
      RNode{a, b}

def dummy() -> Rw:
  Sp{0, 0, Nil{}, Nil{}, G.VNil{}}

# row weight if it is a pivot candidate (Sp with w >= 1), else 0
def rw_w(r: Rw) -> U32:
  match r:
    case Sp{id, w, act, ina, rhs}:
      w
    case Dn{id, co, rhs}:
      0

def best2.go(takea: Bool, a: Rw, b: Rw) -> Rw:
  match takea:
    case True{}:
      a
    case False{}:
      b

# the better pivot candidate: smaller positive weight wins (ties: the first)
def best2(+a: Rw, +b: Rw) -> Rw:
  best2.go(Bool.or(U32.is_eq(rw_w(b), 0), band(U32.is_ne(rw_w(a), 0), U32.is_le(rw_w(a), rw_w(b)))), a, b)

def rw_cand.go(none: Bool, r: Rw) -> Rw:
  match none:
    case True{}:
      dummy()
    case False{}:
      r

def rw_cand(+r: Rw) -> Rw:
  rw_cand.go(U32.is_eq(rw_w(r), 0), r)

def rp_join(a: RP, b: RP) -> RP:
  match a b:
    case RP{ta, ba} RP{tb, bb}:
      RP{rt_node(ta, tb), best2(ba, bb)}

# ---- does the pivot step touch this row's active part? -------------------------------------
def in_s(s: List<&2, U32>, +c: U32) -> Bool:
  match s:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(U32.is_eq(h, c), in_s(t, c))

def hit(act: List<&2, T.Term>, +pc: U32, +s: List<&2, U32>) -> Bool:
  match act:
    case Nil{}:
      False{}
    case h <> t:
      match h:
        case T.Term{+c, f}:
          Bool.or(U32.is_eq(c, pc), Bool.or(in_s(s, c), hit(t, pc, s)))

# state of the scan: f = coefficient of pc, w = surviving active weight, rest (rev), moved (rev)
type Sc is Data:
  Sc{f: U32, w: U32, rest: List<&2, T.Term>, moved: List<&2, T.Term>}

def sc_step(k: U32, c: U32, x: U32, st: Sc) -> Sc:
  match k:
    case 0:
      match st:
        case Sc{f, w, rest, moved}:
          Sc{f, (w + 1 : U32), T.Term{c, x} <> rest, moved}
    case 1:
      match st:
        case Sc{f, w, rest, moved}:
          Sc{x, w, rest, moved}
    case _:
      match st:
        case Sc{f, w, rest, moved}:
          Sc{f, w, rest, T.Term{c, x} <> moved}

def sc_class.go(isp: Bool, ins: Bool) -> U32:
  match isp:
    case True{}:
      1
    case False{}:
      match ins:
        case True{}:
          2
        case False{}:
          0

def sc_class(+c: U32, +pc: U32, s: List<&2, U32>) -> U32:
  sc_class.go(U32.is_eq(c, pc), in_s(s, c))

def sc_go(act: List<&2, T.Term>, +pc: U32, +s: List<&2, U32>, st: Sc) -> Sc:
  match act:
    case Nil{}:
      match st:
        case Sc{f, w, rest, moved}:
          Sc{f, w, List.reverse(&2, T.Term, rest), List.reverse(&2, T.Term, moved)}
    case h <> t:
      match h:
        case T.Term{+c, x}:
          sc_go(t, pc, s, sc_step(sc_class(c, pc, s), c, x, st))

# ---- eliminate the pivot step from one sparse row -------------------------------------------
def elim_sp.fin2(+g: U32, id: U32, w: U32, rest: List<&2, T.Term>, ina: List<&2, T.Term>, rhs: G.Vec, pina: List<&2, T.Term>, prhs: G.Vec) -> Rw:
  match g:
    case 0:
      Sp{id, w, rest, ina, rhs}
    case _:
      Sp{id, w, rest, tmerge(g, ina, pina), G.Vec.muladd(g, rhs, prhs)}

def elim_sp.fin(sc: Sc, id: U32, ina: List<&2, T.Term>, rhs: G.Vec, +pcf: U32, pina: List<&2, T.Term>, prhs: G.Vec) -> Rw:
  match sc:
    case Sc{f, w, rest, moved}:
      elim_sp.fin2(G.div(f, pcf), id, w, rest, tmerge(1, ina, moved), rhs, pina, prhs)

def elim_sp.go(h: Bool, id: U32, w: U32, act: List<&2, T.Term>, ina: List<&2, T.Term>, rhs: G.Vec, st: Stp) -> Rw:
  match h:
    case False{}:
      Sp{id, w, act, ina, rhs}
    case True{}:
      match st:
        case Stp{pc, pcf, s, pina, prhs, pid}:
          elim_sp.fin(sc_go(act, pc, s, Sc{0, 0, Nil{}, Nil{}}), id, ina, rhs, pcf, pina, prhs)

# ---- eliminate from one dense row ----------------------------------------------------------
def apply_terms(ts: List<&2, T.Term>, co: G.Vec, +g: U32, +nw: U32) -> G.Vec:
  match ts:
    case Nil{}:
      co
    case h <> t:
      match h:
        case T.Term{c, f}:
          apply_terms(t, vxor_oct(co, c, nw, G.mul(g, f)), g, nw)

def elim_dn.go(+g: U32, +f: U32, id: U32, co: G.Vec, rhs: G.Vec, +pc: U32, +nw: U32, pina: List<&2, T.Term>, prhs: G.Vec) -> Rw:
  match g:
    case 0:
      Dn{id, co, rhs}
    case _:
      Dn{id, apply_terms(pina, vxor_oct(co, pc, nw, f), g, nw), G.Vec.muladd(g, rhs, prhs)}

def elim_dn(id: U32, +co: G.Vec, rhs: G.Vec, st: Stp, +nw: U32) -> Rw:
  match st:
    case Stp{+pc, +pcf, s, pina, prhs, pid}:
      +f = vget_oct(co, pc, nw)
      elim_dn.go(G.div(f, pcf), f, id, co, rhs, pc, nw, pina, prhs)

def elim(r: Rw, st: Stp, nw: U32) -> Rw:
  match r:
    case Sp{id, w, +act, ina, rhs}:
      match st:
        case Stp{+pc, pcf, +s, pina, prhs, pid}:
          elim_sp.go(hit(act, pc, s), id, w, act, ina, rhs, Stp{pc, pcf, s, pina, prhs, pid})
    case Dn{id, co, rhs}:
      elim_dn(id, co, rhs, st, nw)

# ---- the parallel pass: eliminate everywhere + reduce to the next pivot candidate -----------
def rw_leaf.go(isp: Bool, r: Rw, st: Stp, nw: U32) -> RP:
  match isp:
    case True{}:
      RP{RNil{}, dummy()}
    case False{}:
      +r2 = elim(r, st, nw)
      RP{RLeaf{r2}, rw_cand(r2)}

def rw_id(r: Rw) -> U32:
  match r:
    case Sp{id, w, act, ina, rhs}:
      id
    case Dn{id, co, rhs}:
      id

def rp_pass(t: RT, +st: Stp, +nw: U32) -> RP:
  match t:
    case RNil{}:
      RP{RNil{}, dummy()}
    case RLeaf{+r}:
      match st:
        case Stp{pc, pcf, s, pina, prhs, +pid}:
          rw_leaf.go(U32.is_eq(rw_id(r), pid), r, Stp{pc, pcf, s, pina, prhs, pid}, nw)
    case RNode{l, r}:
      a b = rp_pass(l, st, nw) rp_pass(r, st, nw)
      rp_join(a, b)

# best candidate over the whole tree (parallel reduce)
def rt_best(t: RT) -> Rw:
  match t:
    case RNil{}:
      dummy()
    case RLeaf{r}:
      rw_cand(r)
    case RNode{l, r}:
      a b = rt_best(l) rt_best(r)
      best2(a, b)

def cols_of(ts: List<&2, T.Term>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case T.Term{c, f}:
          c <> cols_of(t)

def ph_of(rp: RP, pivs: List<&2, Pv>) -> Ph:
  match rp:
    case RP{t, best}:
      Ph{t, best, pivs}

def ph1_go(+pc: U32, +pcf: U32, s: List<&2, U32>, +pina: List<&2, T.Term>, id: U32, +rhs: G.Vec, t: RT, pivs: List<&2, Pv>, nw: U32) -> Ph:
  ph_of(rp_pass(t, Stp{pc, pcf, s, pina, rhs, id}, nw), Pv{pc, pcf, pina, rhs} <> pivs)

# one pivot step: pc = first active column of the chosen row, the other active columns are inactivated
def ph1_step(pc: U32, pcf: U32, +rest: List<&2, T.Term>, id: U32, ina: List<&2, T.Term>, rhs: G.Vec, t: RT, pivs: List<&2, Pv>, nw: U32) -> Ph:
  ph1_go(pc, pcf, cols_of(rest), tmerge(1, ina, rest), id, rhs, t, pivs, nw)

# fuel k >= number of columns.  Stops when no sparse row has an active column left.
def ph1(k: Nat, st: Ph, +nw: U32) -> Ph:
  match k:
    case 0n:
      st
    case 1n+p:
      match st:
        case Ph{t, best, pivs}:
          match best:
            case Sp{id, w, act, ina, rhs}:
              match act:
                case Nil{}:
                  Ph{t, dummy(), pivs}
                case h <> rest:
                  match h:
                    case T.Term{pc, pcf}:
                      ph1(p, ph1_step(pc, pcf, rest, id, ina, rhs, t, pivs, nw), nw)
            case Dn{id, co, rhs}:
              Ph{t, dummy(), pivs}

# ===========================================================================
# 7. Phase 2: dense solve over the inactive columns Ci = all columns that are not pivots
# ===========================================================================

def rt_flat(t: RT, acc: List<&2, Rw>) -> List<&2, Rw>:
  match t:
    case RNil{}:
      acc
    case RLeaf{r}:
      r <> acc
    case RNode{l, r}:
      rt_flat(l, rt_flat(r, acc))

def pivcols(pivs: List<&2, Pv>, acc: List<&2, U32>) -> List<&2, U32>:
  match pivs:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case Pv{pc, pcf, pina, rhs}:
          pivcols(t, pc <> acc)

# complement of the sorted pivot columns in 0..l-1 (fuel = l)
def compl(f: Nat, +c: U32, pcs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match f:
    case 0n:
      List.reverse(&2, U32, acc)
    case 1n+q:
      match pcs:
        case Nil{}:
          compl(q, (c + 1 : U32), Nil{}, c <> acc)
        case +h <> +t:
          +isp = U32.is_eq(h, c)
          compl(q, (c + 1 : U32), pick_l(isp, t, h <> t), pick_l(isp, acc, c <> acc))

# sparse row (sorted terms over inactive columns) -> dense coefficient Vec over Ci positions
type Wk is Data:
  Wk{co: G.Vec, ts: List<&2, T.Term>, ci: List<&2, U32>, pos: U32}

def wk_step(k: Cmp, co: G.Vec, +hc: U32, +hf: U32, tt: List<&2, T.Term>, +c: U32, ct: List<&2, U32>, +pos: U32, +nw: U32) -> Wk:
  match k:
    case EQ{}:
      Wk{vxor_oct(co, pos, nw, hf), tt, ct, (pos + 1 : U32)}
    case LT{}:
      Wk{co, T.Term{hc, hf} <> tt, ct, (pos + 1 : U32)}
    case GT{}:
      Wk{co, tt, c <> ct, pos}

def wk_pair(co: G.Vec, h: T.Term, tt: List<&2, T.Term>, +c: U32, ct: List<&2, U32>, pos: U32, nw: U32) -> Wk:
  match h:
    case T.Term{+hc, hf}:
      wk_step(U32.cmp(c, hc), co, hc, hf, tt, c, ct, pos, nw)

def wk_go(f: Nat, st: Wk, +nw: U32) -> G.Vec:
  match f:
    case 0n:
      match st:
        case Wk{co, ts, ci, pos}:
          co
    case 1n+q:
      match st:
        case Wk{co, ts, ci, pos}:
          match ts ci:
            case Nil{} _:
              co
            case _ Nil{}:
              co
            case h <> tt c <> ct:
              wk_go(q, wk_pair(co, h, tt, c, ct, pos, nw), nw)

def sp_dense(+ts: List<&2, T.Term>, +ci: List<&2, U32>, zero: G.Vec, nw: U32) -> G.Vec:
  wk_go(List.length(&2, U32, List.append(&2, U32, ci, List.append(&2, U32, cols_of(ts), Nil{}))), Wk{zero, ts, ci, 0}, nw)

# dense row over all columns -> its entries at the columns Ci
def dn_dense(ci: List<&2, U32>, +pos: U32, +src: G.Vec, +nws: U32, dst: G.Vec, +nwd: U32) -> G.Vec:
  match ci:
    case Nil{}:
      dst
    case c <> ct:
      dn_dense(ct, (pos + 1 : U32), src, nws, vxor_oct(dst, pos, nwd, vget_oct(src, c, nws)), nwd)

def rw_dg(r: Rw, +id: U32, +ci: List<&2, U32>, +zero: G.Vec, +nws: U32, +nwd: U32) -> DG:
  match r:
    case Sp{rid, w, act, ina, rhs}:
      DG{id, 0, sp_dense(ina, ci, zero, nwd), rhs}
    case Dn{rid, co, rhs}:
      DG{id, 0, dn_dense(ci, 0, co, nws, zero, nwd), rhs}

def rw_dgs(rs: List<&2, Rw>, +ci: List<&2, U32>, +zero: G.Vec, +nws: U32, +nwd: U32, +id: U32, acc: List<&2, DT>) -> List<&2, DT>:
  match rs:
    case Nil{}:
      List.reverse(&2, DT, acc)
    case r <> rest:
      rw_dgs(rest, ci, zero, nws, nwd, (id + 1 : U32), DTLeaf{rw_dg(r, id, ci, zero, nws, nwd)} <> acc)

# (position, symbol) pairs -> (column, symbol) pairs by walking Ci
def zip_ci(syms: List<G.Vec>, ci: List<&2, U32>, acc: List<&2, Pr>) -> List<&2, Pr>:
  match syms ci:
    case v <> vt c <> ct:
      zip_ci(vt, ct, Pr{c, v} <> acc)
    case _ _:
      acc

# ===========================================================================
# 8. Phase 3: back-substitution of every pivot row (independent => parallel)
# ===========================================================================

type PT is Data:
  PNil{}
  PLeaf{p: Pv}
  PNode{l: PT, r: PT}

def pt_node(l: PT, r: PT) -> PT:
  match l r:
    case PNil{} PNil{}:
      PNil{}
    case a b:
      PNode{a, b}

def pt_pair(xs: List<&2, PT>, acc: List<&2, PT>) -> List<&2, PT>:
  match xs:
    case Nil{}:
      List.reverse(&2, PT, acc)
    case a <> rest:
      match rest:
        case Nil{}:
          List.reverse(&2, PT, a <> acc)
        case b <> r2:
          pt_pair(r2, pt_node(a, b) <> acc)

def pt_build(+d: Nat, xs: List<&2, PT>) -> PT:
  match d:
    case 0n:
      PNil{}
    case 1n+p:
      match xs:
        case Nil{}:
          PNil{}
        case a <> Nil{}:
          a
        case a <> b <> rest:
          pt_build(p, pt_pair(a <> b <> rest, Nil{}))

def pt_leaves(pivs: List<&2, Pv>, acc: List<&2, PT>) -> List<&2, PT>:
  match pivs:
    case Nil{}:
      List.reverse(&2, PT, acc)
    case h <> t:
      pt_leaves(t, PLeaf{h} <> acc)

# rhs ^ sum(coef * C[col]) over the inactive terms
def bs_terms(ts: List<&2, T.Term>, acc: G.Vec, +iv: ST, +l: U32) -> G.Vec:
  match ts:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case T.Term{c, f}:
          bs_terms(t, G.Vec.muladd(f, acc, st_get(32n, iv, 0, l, c)), iv, l)

def bs_one(p: Pv, iv: ST, l: U32) -> Pv:
  match p:
    case Pv{pc, pcf, pina, rhs}:
      Pv{pc, 1, Nil{}, G.Vec.scale(G.inv(pcf), bs_terms(pina, rhs, iv, l))}

def bs_map(t: PT, +iv: ST, +l: U32) -> PT:
  match t:
    case PNil{}:
      PNil{}
    case PLeaf{p}:
      PLeaf{bs_one(p, iv, l)}
    case PNode{a, b}:
      x y = bs_map(a, iv, l) bs_map(b, iv, l)
      PNode{x, y}

def pt_collect(t: PT, acc: List<&2, Pr>) -> List<&2, Pr>:
  match t:
    case PNil{}:
      acc
    case PLeaf{p}:
      match p:
        case Pv{pc, pcf, pina, rhs}:
          Pr{pc, rhs} <> acc
    case PNode{a, b}:
      pt_collect(a, pt_collect(b, acc))

# ===========================================================================
# 9. Driver
# ===========================================================================

# more terms than this => the row is held as a dense coefficient vector
def DENSE_TERMS() -> U32:
  16

def rw_of.go(dense: Bool, id: U32, +cols: List<&2, T.Term>, rhs: G.Vec, +l: U32, +p: U32, +zero: G.Vec, +nw: U32) -> Rw:
  match dense:
    case True{}:
      Dn{id, fold_terms(cols, zero, nw), rhs}
    case False{}:
      +lim = (l - p : U32)
      +acts = tsort(ts_flt(cols, lim, True{}, Nil{}))
      inas = tsort(ts_flt(cols, lim, False{}, Nil{}))
      Sp{id, U32.from_nat(List.length(&2, T.Term, acts)), acts, inas, rhs}

def rw_of(id: U32, r: T.Row, l: U32, p: U32, zero: G.Vec, nw: U32) -> Rw:
  match r:
    case T.Row{+cols, rhs}:
      rw_of.go(U32.is_gt(U32.from_nat(List.length(&2, T.Term, cols)), DENSE_TERMS()), id, cols, rhs, l, p, zero, nw)

def rw_leaves(rows: List<T.Row>, +l: U32, +p: U32, +zero: G.Vec, +nw: U32, +id: U32, acc: List<&2, RT>) -> List<&2, RT>:
  match rows:
    case Nil{}:
      List.reverse(&2, RT, acc)
    case r <> rest:
      rw_leaves(rest, l, p, zero, nw, (id + 1 : U32), RLeaf{rw_of(id, r, l, p, zero, nw)} <> acc)

def rt_pair(xs: List<&2, RT>, acc: List<&2, RT>) -> List<&2, RT>:
  match xs:
    case Nil{}:
      List.reverse(&2, RT, acc)
    case a <> rest:
      match rest:
        case Nil{}:
          List.reverse(&2, RT, a <> acc)
        case b <> r2:
          rt_pair(r2, rt_node(a, b) <> acc)

def rt_build(+d: Nat, xs: List<&2, RT>) -> RT:
  match d:
    case 0n:
      RNil{}
    case 1n+p:
      match xs:
        case Nil{}:
          RNil{}
        case a <> Nil{}:
          a
        case a <> b <> rest:
          rt_build(p, rt_pair(a <> b <> rest, Nil{}))

# phase 3 + assembly: inactive pairs (col, sym) and the pivot rows -> C[0..l-1]
def finish(+l: U32, pivs: List<&2, Pv>, +inact: List<&2, Pr>) -> List<G.Vec>:
  +iv = st_build(32n, l, 0, inact)
  st_to_list(st_build(32n, l, 0, pt_collect(bs_map(pt_build(32n, pt_leaves(pivs, Nil{})), iv, l), inact)), Nil{})

# phase 2 result -> finish
def phase2_fin(res: Maybe<&2, List<&2, Pr>>, +n: U32, ci: List<&2, U32>, +l: U32, pivs: List<&2, Pv>) -> Maybe<List<G.Vec>>:
  match res:
    case None{}:
      None{}
    case Some{ps}:
      Some{finish(l, pivs, zip_ci(st_to_list(st_build(32n, n, 0, ps), Nil{}), ci, Nil{}))}

def phase2.go2(+n: U32, +ci: List<&2, U32>, t: RT, pivs: List<&2, Pv>, l: U32, nw: U32) -> Maybe<List<G.Vec>>:
  +nwd = nwords(n)
  phase2_fin(dg_run(dt_build(32n, rw_dgs(rt_flat(t, Nil{}), ci, zero_vec(nwd), nw, nwd, 1, Nil{})), n, nwd), n, ci, l, pivs)

def phase2.go(+ci: List<&2, U32>, t: RT, pivs: List<&2, Pv>, l: U32, nw: U32) -> Maybe<List<G.Vec>>:
  phase2.go2(U32.from_nat(List.length(&2, U32, ci)), ci, t, pivs, l, nw)

def phase2(+t: RT, +pivs: List<&2, Pv>, +l: U32, +nw: U32) -> Maybe<List<G.Vec>>:
  phase2.go(compl(U32.to_nat(l), 0, List.sort(~U32, ~u32_le, pivcols(pivs, Nil{})), Nil{}), t, pivs, l, nw)

def phase1_fin(st: Ph, l: U32, nw: U32) -> Maybe<List<G.Vec>>:
  match st:
    case Ph{t, best, pivs}:
      phase2(t, pivs, l, nw)

# Inactivation decoding.  p = number of permanently inactive columns (the last p columns).
def Solver.solve_p(+l: U32, +p: U32, rows: List<T.Row>) -> Maybe<List<G.Vec>>:
  +nw = nwords(l)
  +t = rt_build(32n, rw_leaves(rows, l, p, zero_vec(nw), nw, 1, Nil{}))
  phase1_fin(ph1(U32.to_nat(l), Ph{t, rt_best(t), Nil{}}, nw), l, nw)

def Solver.solve(l: U32, rows: List<T.Row>) -> Maybe<List<G.Vec>>:
  Solver.solve_p(l, 0, rows)
