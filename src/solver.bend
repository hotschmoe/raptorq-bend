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

# Fork depth of the parallel tree passes: 2^PAR tasks per pass (see docs/solver.md, thread scaling).
def PAR() -> Nat:
  0n

# fuel for loops that stop on their own (termination checker: the Nat only has to be big enough)
def FUEL() -> Nat:
  1000000000n

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
# Sequential symbol ops.  G.Vec.xor/muladd/scale fork at EVERY tree node (down to single words), which
# costs far more than the work for symbol sizes of a few words and made multi-threaded runs several
# times slower than --threads 1.  The solver gets its parallelism from the row-level tree passes (hundreds
# of independent row updates per pass), so each row update uses these plain sequential versions.
# ---------------------------------------------------------------------------
def sv_xor(a: G.Vec, b: G.Vec) -> G.Vec:
  match a b:
    case G.VNode{al, ar} G.VNode{bl, br}:
      G.VNode{sv_xor(al, bl), sv_xor(ar, br)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, y)}
    case x _:
      x

def sv_muladd.go(+c: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match dst src:
    case G.VNode{dl, dr} G.VNode{sl, sr}:
      G.VNode{sv_muladd.go(c, dl, sl), sv_muladd.go(c, dr, sr)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, G.mulw(c, y))}
    case x _:
      x

# dst ^ c*src
def sv_muladd(c: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match c:
    case 0:
      dst
    case 1:
      sv_xor(dst, src)
    case _:
      sv_muladd.go(c, dst, src)

def sv_scale.go(+c: U32, v: G.Vec) -> G.Vec:
  match v:
    case G.VNode{l, r}:
      G.VNode{sv_scale.go(c, l), sv_scale.go(c, r)}
    case G.VWord{w}:
      G.VWord{G.mulw(c, w)}
    case G.VNil{}:
      G.VNil{}

def sv_scale(c: U32, v: G.Vec) -> G.Vec:
  match c:
    case 0:
      G.Vec.zeros(v)
    case 1:
      v
    case _:
      sv_scale.go(c, v)

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
      +co2 = sv_muladd(f, co, pco)
      +r2 = {DG{id, piv, co2, sv_muladd(f, rhs, prhs)} : DG}
      +ok = band(U32.is_eq(piv, 0), U32.is_ne(vget_oct(co2, nc, nw), 0))
      DP{DTLeaf{r2}, dg_cand(ok, r2)}

def dg_leaf(r: DG, c: U32, nw: U32, nc: U32, pco: G.Vec, prhs: G.Vec, pid: U32) -> DP:
  match r:
    case DG{+id, piv, co, rhs}:
      dg_leaf.go(U32.is_eq(id, pid), id, piv, co, rhs, c, nw, nc, pco, prhs)

def dg_pass(+par: Nat, t: DT, +c: U32, +nw: U32, +nc: U32, +pco: G.Vec, +prhs: G.Vec, +pid: U32) -> DP:
  match par:
    case 0n:
      match t:
        case DTNil{}:
          DP{DTNil{}, CNone{}}
        case DTLeaf{r}:
          dg_leaf(r, c, nw, nc, pco, prhs, pid)
        case DTNode{l, r}:
          a = dg_pass(par, l, c, nw, nc, pco, prhs, pid)
          b = dg_pass(par, r, c, nw, nc, pco, prhs, pid)
          dp_join(a, b)
    case 1n+q:
      match t:
        case DTNil{}:
          DP{DTNil{}, CNone{}}
        case DTLeaf{r}:
          dg_leaf(r, c, nw, nc, pco, prhs, pid)
        case DTNode{l, r}:
          a b = dg_pass(q, l, c, nw, nc, pco, prhs, pid) dg_pass(q, r, c, nw, nc, pco, prhs, pid)
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
      cand_or(dg_find(l, c, nw), dg_find(r, c, nw))

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
def dg_loop(k: Nat, +par: Nat, st: DP, +c: U32, +n: U32, +nw: U32) -> Maybe<&2, List<&2, Pr>>:
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
                  +pco = sv_scale(iv, co)
                  +prhs = sv_scale(iv, rhs)
                  nc = U32.min((c + 1 : U32), (n - 1 : U32))
                  dg_loop(p, par, dg_pass(par, t, c, nw, nc, pco, prhs, id), (c + 1 : U32), n, nw)

def dg_run(+par: Nat, +t: DT, +n: U32, +nw: U32) -> Maybe<&2, List<&2, Pr>>:
  dg_loop(U32.to_nat(n), par, DP{t, dg_find(t, 0, nw)}, 0, n, nw)

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
          SN{st_build(p, h, lo, flt(xs, mid, True{}, Nil{})), st_build(p, (w - h : U32), mid, flt(xs, mid, False{}, Nil{}))}

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

def st_to_list(t: ST, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
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

def dg_rows(rows: List<&2, T.Row>, +zero: G.Vec, +nw: U32, +id: U32, acc: List<&2, DT>) -> List<&2, DT>:
  match rows:
    case Nil{}:
      List.reverse(&2, DT, acc)
    case r <> rest:
      dg_rows(rest, zero, nw, (id + 1 : U32), DTLeaf{row_dg(zero, nw, id, r)} <> acc)

# pivot pairs (index = column) -> the solution list C[0..n-1]
def dense_fin(res: Maybe<&2, List<&2, Pr>>, +n: U32) -> Maybe<&2, List<&2, G.Vec>>:
  match res:
    case None{}:
      None{}
    case Some{ps}:
      Some{st_to_list(st_build(32n, n, 0, ps), Nil{})}

# Plain Gauss-Jordan over the whole system (test oracle).
def Solver.solve_dense(+l: U32, rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  +nw = nwords(l)
  dense_fin(dg_run(0n, dt_build(32n, dg_rows(rows, zero_vec(nw), nw, 0, Nil{})), l, nw), l)

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
      mg_go(FUEL(), g, Mg{Nil{}, a, b})

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
# 6. Phase 1: sparse elimination with inactivation, driven by a column -> rows index
# ===========================================================================
# Phase 1 only decides WHICH rows pivot on WHICH columns and which columns are inactivated; it works on the
# small "active" parts of the rows and never touches symbols or inactive coefficients.  Every row instead
# records a log of the eliminations it received (g, j): "row += g * pivot row number j".  The inactive
# coefficient vectors and the symbols are computed from these logs afterwards (section 7, `mat_*`).
#
# Sp = sparse row: act = terms in ACTIVE columns (sorted by column, w = |act|), own = terms the row itself has
#      in INACTIVE columns, as Term{position, coef} with the newest position first (a column's position is
#      its rank in the order of inactivation: permanent columns 0..p-1, then every inactivated column in turn;
#      so new terms are simply consed on), log = eliminations received, oc/r0 = the normalised ORIGINAL terms
#      (by column) and rhs (phase-3 forward substitution).
# Dn = dense row: coefficient Vec over all l columns (HDPC-like rows); never a pivot, corrected at the end.
type Lg is Data:
  Lg{g: U32, j: U32}

type Rw is Data:
  Sp{id: U32, w: U32, act: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec}
  Dn{id: U32, co: G.Vec, rhs: G.Vec}

# One elimination step: pivot column pc (coefficient pcf in the pivot row), columns s = Term{column, position}
# are inactivated (sorted by column), j = number of the pivot.
type Stp is Data:
  Stp{pc: U32, pcf: U32, s: List<&2, T.Term>, j: U32}

# A finished pivot (in selection order): column, frozen coefficient of pc, the row's own inactive terms
# (including the terms moved at its own step), its elimination log, and its original equation.
type Pv is Data:
  Pv{pc: U32, pcf: U32, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec}

# n = number of pivots, l = pivots (newest first), nin = number of dynamically inactivated columns,
# il = those columns (newest first), p = number of permanently inactive columns.
type Pl is Data:
  Pl{n: U32, l: List<&2, Pv>, nin: U32, il: List<&2, U32>, p: U32}

def dummy() -> Rw:
  Sp{4294967295, 0, Nil{}, Nil{}, Nil{}, Nil{}, G.VNil{}}

def rw_id(r: Rw) -> U32:
  match r:
    case Sp{id, w, act, own, log, oc, r0}:
      id
    case Dn{id, co, rhs}:
      id

def is_live(r: Rw) -> Bool:
  U32.is_ne(rw_id(r), 4294967295)

# active weight of a sparse row (0 for dense rows)
def rw_w(r: Rw) -> U32:
  match r:
    case Sp{id, w, act, own, log, oc, r0}:
      w
    case Dn{id, co, rhs}:
      0

# ---- does the pivot step touch this row's active part? -------------------------------------
# position + 1 of column c in s (sorted terms Term{column, position}), 0 if absent
def in_s(s: List<&2, T.Term>, +c: U32) -> U32:
  match s:
    case Nil{}:
      0
    case T.Term{+h, +pos} <> t:
      (U32.and(b2m(U32.is_eq(h, c)), (pos + 1 : U32)) .|. in_s(t, c) : U32)

def hit(act: List<&2, T.Term>, +pc: U32, +s: List<&2, T.Term>) -> Bool:
  match act:
    case Nil{}:
      False{}
    case h <> t:
      match h:
        case T.Term{+c, f}:
          Bool.or(U32.is_eq(c, pc), Bool.or(U32.is_ne(in_s(s, c), 0), hit(t, pc, s)))

# state of the scan: f = coefficient of pc, w = surviving active weight, rest (rev), moved (newest position first)
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
          Sc{f, w, rest, T.Term{(k - 2 : U32), x} <> moved}

# 0 = stays active, 1 = the pivot column, 2 + position = inactivated now
def sc_class.go(isp: Bool, +ins: U32) -> U32:
  match isp:
    case True{}:
      1
    case False{}:
      match ins:
        case 0:
          0
        case _:
          (ins + 1 : U32)

def sc_class(+c: U32, +pc: U32, s: List<&2, T.Term>) -> U32:
  sc_class.go(U32.is_eq(c, pc), in_s(s, c))

def sc_go(act: List<&2, T.Term>, +pc: U32, +s: List<&2, T.Term>, st: Sc) -> Sc:
  match act:
    case Nil{}:
      match st:
        case Sc{f, w, rest, moved}:
          Sc{f, w, List.reverse(&2, T.Term, rest), moved}
    case h <> t:
      match h:
        case T.Term{+c, x}:
          sc_go(t, pc, s, sc_step(sc_class(c, pc, s), c, x, st))

# ---- eliminate the pivot step from one sparse row -------------------------------------------
def elim_sp.fin2(+g: U32, +j: U32, id: U32, w: U32, rest: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec) -> Rw:
  match g:
    case 0:
      Sp{id, w, rest, own, log, oc, r0}
    case _:
      Sp{id, w, rest, own, Lg{g, j} <> log, oc, r0}

def elim_sp.fin(sc: Sc, id: U32, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec, +pcf: U32, +j: U32) -> Rw:
  match sc:
    case Sc{f, w, rest, moved}:
      elim_sp.fin2(G.div(f, pcf), j, id, w, rest, List.append(&2, T.Term, moved, own), log, oc, r0)

def elim_sp.go(h: Bool, id: U32, w: U32, act: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec, st: Stp) -> Rw:
  match h:
    case False{}:
      Sp{id, w, act, own, log, oc, r0}
    case True{}:
      match st:
        case Stp{pc, pcf, s, j}:
          elim_sp.fin(sc_go(act, pc, s, Sc{0, 0, Nil{}, Nil{}}), id, own, log, oc, r0, pcf, j)

def elim(r: Rw, st: Stp) -> Rw:
  match r:
    case Sp{id, w, +act, own, log, oc, r0}:
      match st:
        case Stp{+pc, pcf, +s, j}:
          elim_sp.go(hit(act, pc, s), id, w, act, own, log, oc, r0, Stp{pc, pcf, s, j})
    case Dn{id, co, rhs}:
      Dn{id, co, rhs}

# ---- the state of phase 1 --------------------------------------------------------------------
# rows : Array<Rw> by row id (dummy where a row is dense, a pivot or being worked on)
# wt   : current active weight of each row (0 = no active column, pivot or dense)
# bk   : bucket by weight: row ids that had this weight when pushed (stale entries are skipped: wt != w)
# ci   : column -> ids of rows that have the column in their active part (only ever shrinks)
type P1 is Type:
  P1{rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl, done: U32}

type CS is Type:
  CS{rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>}

type SC is Type:
  SC{bk: Array<List<&2, U32>>, w: U32, ok: U32}

type GI is Type:
  GI{ci: Array<List<&2, U32>>, ids: List<&2, U32>}

def arr_push2(r: Array<List<&2, U32>> & List<&2, U32>, +w: U32, id: U32) -> Array<List<&2, U32>>:
  match r:
    case Tuple{bk, lst}:
      Array.set(List<&2, U32>, bk, w, id <> lst)

# arr[w] = id <> arr[w]
def arr_push(bk: Array<List<&2, U32>>, +w: U32, id: U32) -> Array<List<&2, U32>>:
  arr_push2(Array.swap(List<&2, U32>, bk, w, Nil{}), w, id)

# weights >= 63 share the last bucket (a row with more than 63 active columns is only picked when nothing lighter is left)
def bkt(+w: U32) -> U32:
  U32.min(w, 63)

def bk_push_if(go: Bool, bk: Array<List<&2, U32>>, w: U32, id: U32) -> Array<List<&2, U32>>:
  match go:
    case True{}:
      arr_push(bk, bkt(w), id)
    case False{}:
      bk

def cols_of(ts: List<&2, T.Term>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case T.Term{c, f}:
          c <> cols_of(t)

# ---- take the index lists of the pivot column and the inactivated columns --------------------
# r = the swap result for the current column; cs = the columns after it
def gather(cs: List<&2, U32>, r: Array<List<&2, U32>> & List<&2, U32>, acc: List<&2, U32>) -> GI:
  match cs r:
    case Nil{} Tuple{ci, l}:
      GI{ci, List.append(&2, U32, l, acc)}
    case +c <> t Tuple{ci, l}:
      gather(t, Array.swap(List<&2, U32>, ci, c, Nil{}), List.append(&2, U32, l, acc))

# ---- eliminate the step from every candidate row (sequential: a handful of small rows per step) ----
def cand_three(+id: U32, +r2: Rw, rows: Array<Rw>, rw: Array<U32> & U32, bk: Array<List<&2, U32>>) -> CS:
  match rw:
    case Tuple{wt, old}:
      +w2 = rw_w(r2)
      CS{Array.set(Rw, rows, id, r2), Array.set(U32, wt, id, w2), bk_push_if(band(U32.is_ne(w2, old), U32.is_ne(w2, 0)), bk, w2, id)}

def cand_two(live: Bool, +id: U32, +st: Stp, rows: Array<Rw>, row: Rw, wt: Array<U32>, bk: Array<List<&2, U32>>) -> CS:
  match live:
    case False{}:
      CS{rows, wt, bk}
    case True{}:
      cand_three(id, elim(row, st), rows, Array.get(U32, wt, id), bk)

def cand_one(+id: U32, +st: Stp, r: Array<Rw> & Rw, wt: Array<U32>, bk: Array<List<&2, U32>>) -> CS:
  match r:
    case Tuple{rows, +row}:
      cand_two(is_live(row), id, st, rows, row, wt, bk)

def cand_loop(ids: List<&2, U32>, +st: Stp, cs: CS) -> CS:
  match ids:
    case Nil{}:
      cs
    case +id <> rest:
      match cs:
        case CS{rows, wt, bk}:
          cand_loop(rest, st, cand_one(id, st, Array.swap(Rw, rows, id, dummy()), wt, bk))

# ---- one pivot step ---------------------------------------------------------------------------
def st8(cs: CS, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match cs:
    case CS{rows, wt, bk}:
      P1{rows, wt, bk, ci, dn, pivs, 0}

def st7(+stp: Stp, pv: Pv, n: U32, l: List<&2, Pv>, nin: U32, il: List<&2, U32>, p: U32, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, dn: List<&2, Rw>, gi: GI) -> P1:
  match gi:
    case GI{ci, ids}:
      st8(cand_loop(ids, stp, CS{rows, wt, bk}), ci, dn, Pl{(n + 1 : U32), pv <> l, nin, il, p})

# positions for the inactivated columns: rest = terms (column, coef) ascending; returns
# s (Term{column, position} ascending), restp (Term{position, coef}, newest first), and the new columns
type Asg is Data:
  Asg{s: List<&2, T.Term>, rp: List<&2, T.Term>}

def asg_go(ts: List<&2, T.Term>, +pos: U32, s: List<&2, T.Term>, rp: List<&2, T.Term>) -> Asg:
  match ts:
    case Nil{}:
      Asg{List.reverse(&2, T.Term, s), rp}
    case T.Term{c, f} <> t:
      asg_go(t, (pos + 1 : U32), T.Term{c, pos} <> s, T.Term{pos, f} <> rp)

def st6b(asg: Asg, +id: U32, +pc: U32, +pcf: U32, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec, +n: U32, l: List<&2, Pv>, +nin: U32, il: List<&2, U32>, p: U32, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>) -> P1:
  match asg:
    case Asg{+s, +rp}:
      st7(Stp{pc, pcf, s, n}, Pv{pc, pcf, List.append(&2, T.Term, rp, own), log, oc, r0}, n, l, (nin + U32.from_nat(List.length(&2, T.Term, s)) : U32), List.append(&2, U32, List.reverse(&2, U32, cols_of(s)), il), p, rows, wt, bk, dn, gather(cols_of(s), Array.swap(List<&2, U32>, ci, pc, Nil{}), Nil{}))

def st6(+id: U32, +pc: U32, +pcf: U32, +rest: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match pivs:
    case Pl{+n, l, +nin, il, +p}:
      st6b(asg_go(rest, (p + nin : U32), Nil{}, Nil{}), id, pc, pcf, own, log, oc, r0, n, l, nin, il, p, rows, wt, bk, ci, dn)

def st5b(+id: U32, h: T.Term, rest: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match h:
    case T.Term{pc, pcf}:
      st6(id, pc, pcf, rest, own, log, oc, r0, rows, wt, bk, ci, dn, pivs)

def st5a(+id: U32, act: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, r0: G.Vec, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match act:
    case Nil{}:
      P1{rows, wt, bk, ci, dn, pivs, 1}
    case h <> rest:
      st5b(id, h, rest, own, log, oc, r0, rows, wt, bk, ci, dn, pivs)

def st5(+id: U32, r: Array<Rw> & Rw, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match r:
    case Tuple{rows, row}:
      match row:
        case Sp{rid, w, act, own, log, oc, r0}:
          st5a(id, act, own, log, oc, r0, rows, wt, bk, ci, dn, pivs)
        case Dn{rid, co, rhs}:
          P1{rows, wt, bk, ci, dn, pivs, 1}

def st4(valid: Bool, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl, +id: U32) -> P1:
  match valid:
    case False{}:
      P1{rows, wt, bk, ci, dn, pivs, 0}
    case True{}:
      st5(id, Array.swap(Rw, rows, id, dummy()), Array.set(U32, wt, id, 0), bk, ci, dn, pivs)

def st3(rows: Array<Rw>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl, +w: U32, +id: U32, bk: Array<List<&2, U32>>, r: Array<U32> & U32) -> P1:
  match r:
    case Tuple{wt, cw}:
      st4(U32.is_eq(bkt(cw), w), rows, wt, bk, ci, dn, pivs, id)

def st2(rows: Array<Rw>, wt: Array<U32>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl, +w: U32, r: Array<List<&2, U32>> & List<&2, U32>) -> P1:
  match r:
    case Tuple{bk, lst}:
      match lst:
        case Nil{}:
          P1{rows, wt, bk, ci, dn, pivs, 1}
        case +id <> rest:
          st3(rows, ci, dn, pivs, w, id, Array.set(List<&2, U32>, bk, w, rest), Array.get(U32, wt, id))

# lowest non-empty bucket >= w (r = the bucket w as returned by Array.get)
def pk_scan(f: Nat, +w: U32, r: Array<List<&2, U32>> & List<&2, U32>) -> SC:
  match f r:
    case 0n Tuple{bk, lst}:
      SC{bk, w, 0}
    case 1n+q Tuple{bk, lst}:
      match lst:
        case Nil{}:
          pk_scan(q, (w + 1 : U32), Array.get(List<&2, U32>, bk, (w + 1 : U32)))
        case _ <> _:
          SC{bk, w, 1}

def st1(rows: Array<Rw>, wt: Array<U32>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl, sc: SC) -> P1:
  match sc:
    case SC{bk, +w, ok}:
      match ok:
        case 0:
          P1{rows, wt, bk, ci, dn, pivs, 1}
        case _:
          st2(rows, wt, ci, dn, pivs, w, Array.swap(List<&2, U32>, bk, w, Nil{}))

# one iteration: pop one entry of the lowest bucket; a stale entry is dropped, a valid one is a pivot step
def p1_step(rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  st1(rows, wt, ci, dn, pivs, pk_scan(63n, 1, Array.get(List<&2, U32>, bk, 1)))

def p1_loop(k: Nat, st: P1) -> P1:
  match k st:
    case 0n _:
      st
    case 1n+q P1{rows, wt, bk, ci, dn, pivs, done}:
      match done:
        case 0:
          p1_loop(q, p1_step(rows, wt, bk, ci, dn, pivs))
        case _:
          P1{rows, wt, bk, ci, dn, pivs, 1}

# ---- building the phase-1 state from the input rows ------------------------------------------
type IN is Type:
  IN{rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>}

# a row is dense (HDPC-like) if it has many terms AND a sizeable fraction of all columns
def DENSE_MIN() -> U32:
  48

def is_dense(+n: U32, +l: U32) -> Bool:
  band(U32.is_gt(n, DENSE_MIN()), U32.is_gt((n * 4 : U32), l))

def ci_add(ts: List<&2, T.Term>, +id: U32, ci: Array<List<&2, U32>>) -> Array<List<&2, U32>>:
  match ts:
    case Nil{}:
      ci
    case h <> t:
      match h:
        case T.Term{c, f}:
          ci_add(t, id, arr_push(ci, c, id))

# columns -> positions of the permanent columns (position = column - lim), order preserved
def ts_pos(ts: List<&2, T.Term>, +lim: U32) -> List<&2, T.Term>:
  match ts:
    case Nil{}:
      Nil{}
    case T.Term{c, f} <> t:
      T.Term{(c - lim : U32), f} <> ts_pos(t, lim)

def init_sparse(+id: U32, +act: List<&2, T.Term>, own: List<&2, T.Term>, +rhs: G.Vec, oc: List<&2, T.Term>, st: IN) -> IN:
  match st:
    case IN{rows, wt, bk, ci, dn}:
      +w = U32.from_nat(List.length(&2, T.Term, act))
      IN{Array.set(Rw, rows, id, Sp{id, w, act, own, Nil{}, oc, rhs}), Array.set(U32, wt, id, w), bk_push_if(U32.is_ne(w, 0), bk, w, id), ci_add(act, id, ci), dn}

def init_dense(id: U32, co: G.Vec, rhs: G.Vec, st: IN) -> IN:
  match st:
    case IN{rows, wt, bk, ci, dn}:
      IN{rows, wt, bk, ci, Dn{id, co, rhs} <> dn}

def init_row3(dense: Bool, +id: U32, +ts: List<&2, T.Term>, +cols: List<&2, T.Term>, rhs: G.Vec, +l: U32, +p: U32, zero: G.Vec, nw: U32, st: IN) -> IN:
  match dense:
    case True{}:
      init_dense(id, fold_terms(cols, zero, nw), rhs, st)
    case False{}:
      +lim = (l - p : U32)
      init_sparse(id, List.reverse(&2, T.Term, ts_flt(ts, lim, True{}, Nil{})), ts_pos(ts_flt(ts, lim, False{}, Nil{}), lim), rhs, ts, st)

def init_row2(+ts: List<&2, T.Term>, cols: List<&2, T.Term>, rhs: G.Vec, +id: U32, +l: U32, +p: U32, zero: G.Vec, nw: U32, st: IN) -> IN:
  init_row3(is_dense(U32.from_nat(List.length(&2, T.Term, ts)), l), id, ts, cols, rhs, l, p, zero, nw, st)

def init_row(r: T.Row, +id: U32, +l: U32, +p: U32, zero: G.Vec, nw: U32, st: IN) -> IN:
  match r:
    case T.Row{+cols, rhs}:
      init_row2(tsort(cols), cols, rhs, id, l, p, zero, nw, st)

def init_go(rs: List<&2, T.Row>, +l: U32, +p: U32, +zero: G.Vec, +nw: U32, +id: U32, st: IN) -> IN:
  match rs:
    case Nil{}:
      st
    case r <> rest:
      init_go(rest, l, p, zero, nw, (id + 1 : U32), init_row(r, id, l, p, zero, nw, st))

# smallest d with 2^d >= n
def clog(+n: U32) -> Nat:
  match n:
    case 0:
      0n
    case 1:
      0n
    case _:
      (1n + U32.log2((n - 1 : U32)) : Nat)

def in_new(+nrows: U32, l: U32) -> IN:
  IN{Array.new(Rw, clog(nrows), dummy()), Array.new(U32, clog(nrows), 0), Array.new(List<&2, U32>, 6n, Nil{}), Array.new(List<&2, U32>, clog(l), Nil{}), Nil{}}

def p1_of(st: IN, p: U32) -> P1:
  match st:
    case IN{rows, wt, bk, ci, dn}:
      P1{rows, wt, bk, ci, dn, Pl{0, Nil{}, 0, Nil{}, p}, 0}

def phase1(+l: U32, +p: U32, +nrows: U32, rows: List<&2, T.Row>, +nw: U32) -> P1:
  p1_loop(FUEL(), p1_of(init_go(rows, l, p, zero_vec(nw), nw, 0, in_new(nrows, l)), p))

# ===========================================================================
# 7. Phase 2: dense solve over the inactive columns Ci = all columns that are not pivots
#    The inactive coefficients and the symbols of pivot rows / leftover rows / dense rows are materialised
#    from the logs: V_k = pack(own_k) + sum g * V_j, R_k = rhs_k + sum g * R_j (j earlier pivots).
# ===========================================================================

def pivcols(pivs: List<&2, Pv>, acc: List<&2, U32>) -> List<&2, U32>:
  match pivs:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case Pv{pc, pcf, own, log, oc, r0}:
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

# dense row over all columns -> its entries at the columns Ci
def dn_dense(ci: List<&2, U32>, +pos: U32, +src: G.Vec, +nws: U32, dst: G.Vec, +nwd: U32) -> G.Vec:
  match ci:
    case Nil{}:
      dst
    case c <> ct:
      dn_dense(ct, (pos + 1 : U32), src, nws, vxor_oct(dst, pos, nwd, vget_oct(src, c, nws)), nwd)

# ---- packed coefficients over Ci positions: own terms Term{position, coef} -> Vec of nwd words ----------
def pk_pos(ts: List<&2, T.Term>, +nwd: U32, v: G.Vec) -> G.Vec:
  match ts:
    case Nil{}:
      v
    case T.Term{pos, f} <> t:
      pk_pos(t, nwd, vxor_oct(v, pos, nwd, f))

# ---- materialise a row from its log: VR{coefficients over Ci, symbol} ---------------------------------
type VR is Data:
  VR{v: G.Vec, r: G.Vec}

type Mt is Type:
  Mt{ar: Array<VR>, acc: VR}

def vr_add(+g: U32, acc: VR, x: VR) -> VR:
  match acc:
    case VR{v, r}:
      match x:
        case VR{xv, xr}:
          VR{sv_muladd(g, v, xv), sv_muladd(g, r, xr)}

# g, r = the current log entry and its pivot's VR (already fetched); lg = the entries after it
def mat_go(lg: List<&2, Lg>, +g: U32, r: Array<VR> & VR, acc: VR) -> Mt:
  match lg r:
    case Nil{} Tuple{ar, x}:
      Mt{ar, vr_add(g, acc, x)}
    case Lg{+g2, j2} <> t Tuple{ar, x}:
      mat_go(t, g2, Array.get(VR, ar, j2), vr_add(g, acc, x))

def mat_start(lg: List<&2, Lg>, ar: Array<VR>, acc: VR) -> Mt:
  match lg:
    case Nil{}:
      Mt{ar, acc}
    case h <> t:
      match h:
        case Lg{+g, j}:
          mat_go(t, g, Array.get(VR, ar, j), acc)

def mat_set(+k: U32, m: Mt) -> Array<VR>:
  match m:
    case Mt{ar, acc}:
      Array.set(VR, ar, k, acc)

# all pivots, oldest first (pvs), k = pivot number
def mat_pivs(pvs: List<&2, Pv>, +k: U32, +nwd: U32, +zero: G.Vec, ar: Array<VR>) -> Array<VR>:
  match pvs:
    case Nil{}:
      ar
    case h <> t:
      match h:
        case Pv{pc, pcf, own, log, oc, r0}:
          mat_pivs(t, (k + 1 : U32), nwd, zero, mat_set(k, mat_start(log, ar, VR{pk_pos(own, nwd, zero), r0})))

# ---- leftover sparse rows -> dense rows of the Ci system -----------------------------------------------
type LR is Type:
  LR{ar: Array<VR>, out: List<&2, DT>}

def lr_fin(+id: U32, m: Mt, out: List<&2, DT>) -> LR:
  match m:
    case Mt{ar, acc}:
      match acc:
        case VR{v, r}:
          LR{ar, DTLeaf{DG{id, 0, v, r}} <> out}

def lr_loop(rs: List<&2, Rw>, +nwd: U32, +zero: G.Vec, +id: U32, st: LR) -> LR:
  match rs st:
    case Nil{} _:
      st
    case Sp{rid, w, act, own, log, oc, r0} <> t LR{ar, out}:
      lr_loop(t, nwd, zero, (id + 1 : U32), lr_fin(id, mat_start(log, ar, VR{pk_pos(own, nwd, zero), r0}), out))
    case Dn{rid, co, rhs} <> t LR{ar, out}:
      lr_loop(t, nwd, zero, id, LR{ar, out})

# ---- the dense rows are corrected for all pivots at the end (not inside the phase-1 loop) ----------------
# A dense row's coefficient at a later pivot column is never changed by earlier pivots (pivot rows only
# contain their own pivot column among pivot columns), so for pivot k: g = orig[pc_k] / pcf_k and
# row -= g * (pivot row k as materialised).
type DS is Data:
  DS{id: U32, co: G.Vec, acc: G.Vec, rhs: G.Vec}

type DM is Type:
  DM{ar: Array<VR>, ds: List<&2, DS>}

def ds_map(ds: List<&2, DS>, +pc: U32, +pcf: U32, +v: G.Vec, +r: G.Vec, +nw: U32) -> List<&2, DS>:
  match ds:
    case Nil{}:
      Nil{}
    case d <> t:
      match d:
        case DS{id, +co, acc, rhs}:
          +g = G.div(vget_oct(co, pc, nw), pcf)
          DS{id, co, sv_muladd(g, acc, v), sv_muladd(g, rhs, r)} <> ds_map(t, pc, pcf, v, r, nw)

def ds_one(pv: Pv, +nw: U32, ds: List<&2, DS>, r: Array<VR> & VR) -> DM:
  match pv r:
    case Pv{pc, pcf, own, log, oc, r0} Tuple{ar, VR{v, rr}}:
      DM{ar, ds_map(ds, pc, pcf, v, rr, nw)}

def ds_loop(pvs: List<&2, Pv>, +k: U32, +nw: U32, st: DM) -> DM:
  match pvs st:
    case Nil{} _:
      st
    case h <> t DM{ar, ds}:
      ds_loop(t, (k + 1 : U32), nw, ds_one(h, nw, ds, Array.get(VR, ar, k)))

def ds_init(rs: List<&2, Rw>, +ci: List<&2, U32>, +nw: U32, +nwd: U32, +id: U32) -> List<&2, DS>:
  match rs:
    case Nil{}:
      Nil{}
    case r <> t:
      match r:
        case Sp{rid, w, act, own, log, oc, r0}:
          ds_init(t, ci, nw, nwd, id)
        case Dn{rid, +co, rhs}:
          DS{id, co, dn_dense(ci, 0, co, nw, zero_vec(nwd), nwd), rhs} <> ds_init(t, ci, nw, nwd, (id + 1 : U32))

def ds_dgs(ds: List<&2, DS>, acc: List<&2, DT>) -> List<&2, DT>:
  match ds:
    case Nil{}:
      acc
    case d <> t:
      match d:
        case DS{id, co, a, rhs}:
          ds_dgs(t, DTLeaf{DG{id, 0, a, rhs}} <> acc)

# (position, symbol) pairs -> (column, symbol) pairs by walking Ci
def zip_ci(syms: List<&2, G.Vec>, ci: List<&2, U32>, acc: List<&2, Pr>) -> List<&2, Pr>:
  match syms ci:
    case v <> vt c <> ct:
      zip_ci(vt, ct, Pr{c, v} <> acc)
    case _ _:
      acc

# the rows that are neither pivots nor dense: Sp rows left in the table
def keep_live.go(live: Bool, x: Rw, acc: List<&2, Rw>) -> List<&2, Rw>:
  match live:
    case True{}:
      x <> acc
    case False{}:
      acc

def keep_live(+x: Rw, acc: List<&2, Rw>) -> List<&2, Rw>:
  keep_live.go(is_live(x), x, acc)

def arr_rows(a: Array<Rw>, acc: List<&2, Rw>) -> List<&2, Rw>:
  match a:
    case ALeaf{x}:
      keep_live(x, acc)
    case ANode{xs, ys}:
      arr_rows(xs, arr_rows(ys, acc))

# ===========================================================================
# 8. Phase 3: forward substitution through the ORIGINAL equations of the pivot rows
#    (pivot k's original row only mentions earlier pivot columns, inactive columns and its own column)
# ===========================================================================
type Q3 is Type:
  Q3{ca: Array<G.Vec>, acc: G.Vec, f: U32}

def q3_mul(+f: U32, acc: G.Vec, f0: U32, r: Array<G.Vec> & G.Vec) -> Q3:
  match r:
    case Tuple{ca, v}:
      Q3{ca, sv_muladd(f, acc, v), f0}

def q3_term(isp: Bool, +c: U32, +f: U32, q: Q3) -> Q3:
  match isp:
    case True{}:
      match q:
        case Q3{ca, acc, f0}:
          Q3{ca, acc, f}
    case False{}:
      match q:
        case Q3{ca, acc, f0}:
          q3_mul(f, acc, f0, Array.get(G.Vec, ca, c))

def q3_fold(ts: List<&2, T.Term>, +pc: U32, q: Q3) -> Q3:
  match ts:
    case Nil{}:
      q
    case h <> t:
      match h:
        case T.Term{+c, f}:
          q3_fold(t, pc, q3_term(U32.is_eq(c, pc), c, f, q))

def p3_set(+pc: U32, q: Q3) -> Array<G.Vec>:
  match q:
    case Q3{ca, acc, f}:
      Array.set(G.Vec, ca, pc, sv_scale(G.inv(f), acc))

def p3_one(pv: Pv, ca: Array<G.Vec>) -> Array<G.Vec>:
  match pv:
    case Pv{+pc, pcf, own, log, oc, r0}:
      p3_set(pc, q3_fold(oc, pc, Q3{ca, r0, 0}))

def p3_loop(pvs: List<&2, Pv>, ca: Array<G.Vec>) -> Array<G.Vec>:
  match pvs:
    case Nil{}:
      ca
    case h <> t:
      p3_loop(t, p3_one(h, ca))

def ca_fill(ps: List<&2, Pr>, ca: Array<G.Vec>) -> Array<G.Vec>:
  match ps:
    case Nil{}:
      ca
    case h <> t:
      match h:
        case Pr{k, v}:
          ca_fill(t, Array.set(G.Vec, ca, k, v))

def arr_to_list(a: Array<G.Vec>, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match a:
    case ALeaf{x}:
      x <> acc
    case ANode{xs, ys}:
      arr_to_list(xs, arr_to_list(ys, acc))

# ===========================================================================
# 9. Driver
# ===========================================================================

# ---- how much to fork: 2^par tasks per pass, only when a pass has enough work to pay for them ----
# (every parallel region costs ~0.3 ms with 12 threads; see docs/perf.md)
def cap(n: Nat, k: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+np:
      match k:
        case 0n:
          0n
        case 1n+kp:
          1n+cap(np, kp)

def par_pick(q: U32) -> Nat:
  match q:
    case 0:
      0n
    case _:
      cap(1n+U32.log2(q), PAR())

# rows = number of independent row updates in a pass, sw = words per row update
def par_for(+rows: U32, +sw: U32) -> Nat:
  par_pick(U32.shrn((rows * (sw + 8) : U32), 15n))

def vwords(v: G.Vec) -> U32:
  match v:
    case G.VNode{l, r}:
      (vwords(l) + vwords(r) : U32)
    case G.VWord{w}:
      1
    case G.VNil{}:
      0

def rows_sw(rows: List<&2, T.Row>) -> U32:
  match rows:
    case Nil{}:
      0
    case r <> rest:
      match r:
        case T.Row{cols, rhs}:
          vwords(rhs)

# phase 2 solution (pairs col -> symbol over Ci) -> C[0..l-1]
def finish(+l: U32, pivs: List<&2, Pv>, inact: List<&2, Pr>) -> List<&2, G.Vec>:
  List.take(&2, G.Vec, arr_to_list(p3_loop(List.reverse(&2, Pv, pivs), ca_fill(inact, Array.new(G.Vec, clog(l), G.VNil{}))), Nil{}), U32.to_nat(l))

def phase2_fin(res: Maybe<&2, List<&2, Pr>>, +n: U32, ci: List<&2, U32>, +l: U32, pivs: List<&2, Pv>) -> Maybe<&2, List<&2, G.Vec>>:
  match res:
    case None{}:
      None{}
    case Some{ps}:
      Some{finish(l, pivs, zip_ci(st_to_list(st_build(32n, n, 0, ps), Nil{}), ci, Nil{}))}

def phase2.go3(+n: U32, +ci: List<&2, U32>, ts: List<&2, DT>, pivs: List<&2, Pv>, l: U32, +sw: U32, +nwd: U32) -> Maybe<&2, List<&2, G.Vec>>:
  phase2_fin(dg_run(par_for(n, (sw + nwd : U32)), dt_build(32n, ts), n, nwd), n, ci, l, pivs)

def ds_fin(dm: DM) -> List<&2, DS>:
  match dm:
    case DM{ar, ds}:
      ds

# leaves of the Ci system: leftover rows (lr) and corrected dense rows (dm)
def phase2.go2(+n: U32, +ci: List<&2, U32>, +pivs: List<&2, Pv>, l: U32, +sw: U32, +nwd: U32, lr: LR, +dn: List<&2, Rw>, +nw: U32, +ords: List<&2, Pv>) -> Maybe<&2, List<&2, G.Vec>>:
  match lr:
    case LR{ar, out}:
      phase2.go3(n, ci, ds_dgs(ds_fin(ds_loop(ords, 0, nw, DM{ar, ds_init(dn, ci, nw, nwd, 1000000000)})), out), pivs, l, sw, nwd)

def phase2.go(+ci: List<&2, U32>, rs: List<&2, Rw>, +dn: List<&2, Rw>, +pivs: List<&2, Pv>, l: U32, sw: U32, +nw: U32) -> Maybe<&2, List<&2, G.Vec>>:
  +n = U32.from_nat(List.length(&2, U32, ci))
  +ords = List.reverse(&2, Pv, pivs)
  +nwd = nwords(n)
  +zero = zero_vec(nwd)
  phase2.go2(n, ci, pivs, l, sw, nwd, lr_loop(rs, nwd, zero, 1, LR{mat_pivs(ords, 0, nwd, zero, Array.new(VR, clog(U32.from_nat(List.length(&2, Pv, pivs))), VR{G.VNil{}, G.VNil{}})), Nil{}}), dn, nw, ords)

# columns in position order: permanent (ascending), then the inactivated ones in the order of inactivation,
# then columns that stayed active but appear in no row
def perm_cols(f: Nat, +c: U32) -> List<&2, U32>:
  match f:
    case 0n:
      Nil{}
    case 1n+q:
      c <> perm_cols(q, (c + 1 : U32))

def phase2.cl(+perm: List<&2, U32>, +dyn: List<&2, U32>, extras: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, perm, List.append(&2, U32, dyn, extras))

def phase2.cl2(+perm: List<&2, U32>, +dyn: List<&2, U32>, +used: List<&2, U32>, +l: U32) -> List<&2, U32>:
  phase2.cl(perm, dyn, compl(U32.to_nat(l), 0, List.sort(~U32, ~u32_le, used), Nil{}))

def phase2(rs: List<&2, Rw>, dn: List<&2, Rw>, +pivs: List<&2, Pv>, il: List<&2, U32>, +p: U32, +l: U32, sw: U32, +nw: U32) -> Maybe<&2, List<&2, G.Vec>>:
  +perm = perm_cols(U32.to_nat(p), (l - p : U32))
  +dyn = List.reverse(&2, U32, il)
  phase2.go(phase2.cl2(perm, dyn, List.append(&2, U32, pivcols(pivs, Nil{}), List.append(&2, U32, dyn, perm)), l), rs, dn, pivs, l, sw, nw)

def phase1_fin(st: P1, l: U32, sw: U32, nw: U32) -> Maybe<&2, List<&2, G.Vec>>:
  match st:
    case P1{rows, wt, bk, ci, dn, pivs, done}:
      match pivs:
        case Pl{n, pl, nin, il, p}:
          phase2(arr_rows(rows, Nil{}), dn, pl, il, p, l, sw, nw)

def solve_go(+l: U32, +p: U32, +sw: U32, +nrows: U32, rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  +nw = nwords(l)
  phase1_fin(phase1(l, p, nrows, rows, nw), l, sw, nw)

# Inactivation decoding.  p = number of permanently inactive columns (the last p columns).
def Solver.solve_p(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  solve_go(l, p, rows_sw(rows), U32.from_nat(List.length(&2, T.Row, rows)), rows)

def Solver.solve(l: U32, rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  Solver.solve_p(l, 0, rows)

# ---------------------------------------------------------------------------
# Symbol slicing (opt-in parallelism).  The symbols of a system are independent of each other: slicing
# every rhs into 2^d word ranges (the subtrees at depth d of the balanced Vec; no copying) and solving the
# 2^d slice systems concurrently gives the same C after joining the slices (VNode{..} of the slice results is
# exactly the shape Vec.from_list builds).  Every slice repeats the symbol-independent work (pivot search,
# coefficient vectors), so this costs CPU time x 2^d and only pays when symbols are long and threads are
# available; see docs/perf.md.  d = 0 is Solver.solve_p.
# ---------------------------------------------------------------------------
def pick_v(left: Bool, l: G.Vec, r: G.Vec) -> G.Vec:
  match left:
    case True{}:
      l
    case False{}:
      r

# the idx-th of the 2^d subtrees at depth d (idx has d bits, most significant bit = first split)
def vsub(+d: Nat, +idx: U32, v: G.Vec) -> G.Vec:
  match d:
    case 0n:
      v
    case 1n+q:
      match v:
        case G.VNode{l, r}:
          vsub(q, U32.and(idx, (U32.shln(1, q) - 1 : U32)), pick_v(U32.is_eq(U32.and(U32.shrn(idx, q), 1), 0), l, r))
        case G.VWord{w}:
          G.VWord{w}
        case G.VNil{}:
          G.VNil{}

def slice_rows(rows: List<&2, T.Row>, +d: Nat, +idx: U32) -> List<&2, T.Row>:
  match rows:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case T.Row{cols, rhs}:
          T.Row{cols, vsub(d, idx, rhs)} <> slice_rows(t, d, idx)

def vjoin(a: List<&2, G.Vec>, b: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match a b:
    case x <> xs y <> ys:
      G.VNode{x, y} <> vjoin(xs, ys)
    case _ _:
      Nil{}

def mjoin(a: Maybe<&2, List<&2, G.Vec>>, b: Maybe<&2, List<&2, G.Vec>>) -> Maybe<&2, List<&2, G.Vec>>:
  match a b:
    case Some{x} Some{y}:
      Some{vjoin(x, y)}
    case _ _:
      None{}

# k = fork levels left, d = total slicing depth, idx = slice prefix
def stree(+k: Nat, +d: Nat, +idx: U32, +l: U32, +p: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  match k:
    case 0n:
      Solver.solve_p(l, p, slice_rows(rows, d, idx))
    case 1n+q:
      a b = stree(q, d, (idx * 2 : U32), l, p, rows) stree(q, d, (idx * 2 + 1 : U32), l, p, rows)
      mjoin(a, b)

def sw_log(+sw: U32) -> Nat:
  match sw:
    case 0:
      0n
    case _:
      U32.log2(sw)

def solve_par2(+dd: Nat, +l: U32, +p: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  match dd:
    case 0n:
      Solver.solve_p(l, p, rows)
    case 1n+q:
      stree(dd, dd, 0, l, p, rows)

# Same answer as Solver.solve_p, with the symbols sliced into 2^min(d, log2(words per symbol)) parts that are
# solved in parallel (see above).  Pass the thread count's log2 (e.g. 3 or 4 for 8..16 slices) or 0.
def Solver.solve_par(+l: U32, +p: U32, +d: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  solve_par2(cap(U32.to_nat(d), sw_log(rows_sw(rows))), l, p, rows)

# Slicing depth for t threads and symbols of sw words: none below 64 words (256 octets), else log2(threads) capped at 3
# (8 slices; 16 slices on 12 threads were slower, see docs/perf.md).
def auto_d.go(small: Bool, +t: U32) -> U32:
  match small:
    case True{}:
      0
    case False{}:
      U32.min(3, U32.from_nat(U32.log2(U32.max(t, 1))))

def auto_d(+t: U32, +sw: U32) -> U32:
  auto_d.go(U32.is_lt(sw, 64), t)

def solve_auto2(t: U32, +l: U32, +p: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  Solver.solve_par(l, p, auto_d(t, rows_sw(rows)), rows)

# Solver.solve_par with the slicing depth chosen from the thread count of the running binary (IO.thread_count)
# and the symbol size.  For callers that live in IO.
def Solver.solve_auto(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  do IO<Maybe<&2, List<&2, G.Vec>>>:
    t : U32 <- IO.thread_count()
    IO.pure(Maybe<&2, List<&2, G.Vec>>, solve_auto2(t, l, p, rows))

# Diagnostics: size of the dense inactive system after phase 1 (columns that are not pivots).
def inactive_count.fin(st: P1, +l: U32) -> U32:
  match st:
    case P1{rows, wt, bk, ci, dn, pivs, done}:
      match pivs:
        case Pl{n, pl, nin, il, p}:
          (l - n : U32)

def Solver.inactive_count(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> U32:
  inactive_count.fin(phase1(l, p, U32.from_nat(List.length(&2, T.Row, rows)), rows, nwords(l)), l)
