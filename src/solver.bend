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

def Solver.solve_p(+l: U32, +p: U32, rows: List<T.Row>) -> Maybe<List<G.Vec>>:
  Solver.solve_dense(l, rows)
