# Linear-system solver over GF(256) -- RFC 6330 section 5.4.2 (inactivation decoding).
#
#   Solver.solve(l, rows)        -> Maybe<List<Sym>>   (inactivation decoding; default entry point)
#   Solver.solve_p(l, p, rows)   -> same, with p = number of permanently inactive columns
#                                   (the LAST p columns, RFC P = L - W); solve = solve_p(l, 0, ..)
#   Solver.solve_par(l, p, d, rows) -> same answer, symbols sliced into 2^d parts solved concurrently
#   Solver.solve_auto(l, p, rows)   -> IO: solve_par with d from IO.thread_count() and the symbol size
#   Solver.plan(l, p, rows)         -> Maybe<Plan>: symbol-independent part (RFC 5.4.2.2); only the coefficients are read
#   Solver.apply(plan, rhs)         -> List<Sym>: the plan replayed on one rhs symbol per row (apply_par / apply_auto: sliced)
#                                      solve / solve_p / solve_par / solve_auto are plan + apply
#   Solver.solve_dense(l, rows)  -> same answer by plain Gauss-Jordan (test oracle)
#   Solver.inactive_count(l, p, rows) -> size of the dense tail (diagnostics)
#
# See docs/solver.md for the design and docs/perf.md for measurements. Overview:
#   phase 1  min-weight pivoting on the small ACTIVE parts of the sparse rows, driven by a column -> rows index and
#            weight buckets; the other active columns of the chosen row are INACTIVATED.  Rows only record a log of
#            the eliminations they received; no symbol or inactive coefficient is touched.
#   mat      inactive coefficient vectors of pivot / leftover rows are computed from the logs (pivot order),
#            the dense (HDPC-like) rows are corrected for every pivot once (all of this on coefficients; symbols in apply).
#   phase 2  the leftover rows over the inactive columns are solved by dense Gauss-Jordan.
#            Both mat and phase 2 run on a flat Array<U32> arena (packed coefficients, src/flat.bend kernels), like apply (section 9);
#            only phase 1 and the row bookkeeping still use lists / Array<Rw>.
#   phase 3  the pivot columns are solved by forward substitution through their original sparse equations.
# A fork reached from sequential code costs a whole runtime round (~0.3 ms), so everything here is sequential except
# solve_par's top-level slice tasks and the (disabled, PAR() = 0) row passes of phase 2.
import Base
import ./gf256.bend as G
import ./types.bend as T
import ./flat.bend as F

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
# 5. Sparse term lists (sorted by column): normalisation
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
#      so new terms are simply consed on), log = eliminations received, oc = the normalised ORIGINAL terms
#      (by column; phase-3 forward substitution), id = the input row number (selects the rhs symbol in Solver.apply).
# Dn = dense row: coefficient Vec over all l columns (HDPC-like rows); never a pivot, corrected at the end.
type Lg is Data:
  Lg{g: U32, j: U32}

type Rw is Data:
  Sp{id: U32, w: U32, act: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>}
  Dn{id: U32, co: G.Vec}

# One elimination step: pivot column pc (coefficient pcf in the pivot row), columns s = Term{column, position}
# are inactivated (sorted by column), j = number of the pivot.
type Stp is Data:
  Stp{pc: U32, pcf: U32, s: List<&2, T.Term>, j: U32}

# A finished pivot (in selection order): column, frozen coefficient of pc, the row's own inactive terms
# (including the terms moved at its own step), its elimination log, and its original equation.
type Pv is Data:
  Pv{pc: U32, pcf: U32, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, id: U32}

# n = number of pivots, l = pivots (newest first), nin = number of dynamically inactivated columns,
# il = those columns (newest first), p = number of permanently inactive columns.
type Pl is Data:
  Pl{n: U32, l: List<&2, Pv>, nin: U32, il: List<&2, U32>, p: U32}

def dummy() -> Rw:
  Sp{4294967295, 0, Nil{}, Nil{}, Nil{}, Nil{}}

def rw_id(r: Rw) -> U32:
  match r:
    case Sp{id, w, act, own, log, oc}:
      id
    case Dn{id, co}:
      id

def is_live(r: Rw) -> Bool:
  U32.is_ne(rw_id(r), 4294967295)

# active weight of a sparse row (0 for dense rows)
def rw_w(r: Rw) -> U32:
  match r:
    case Sp{id, w, act, own, log, oc}:
      w
    case Dn{id, co}:
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
def elim_sp.fin2(+g: U32, +j: U32, id: U32, w: U32, rest: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>) -> Rw:
  match g:
    case 0:
      Sp{id, w, rest, own, log, oc}
    case _:
      Sp{id, w, rest, own, Lg{g, j} <> log, oc}

def elim_sp.fin(sc: Sc, id: U32, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, +pcf: U32, +j: U32) -> Rw:
  match sc:
    case Sc{f, w, rest, moved}:
      elim_sp.fin2(G.div(f, pcf), j, id, w, rest, List.append(&2, T.Term, moved, own), log, oc)

def elim_sp.go(h: Bool, id: U32, w: U32, act: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, st: Stp) -> Rw:
  match h:
    case False{}:
      Sp{id, w, act, own, log, oc}
    case True{}:
      match st:
        case Stp{pc, pcf, s, j}:
          elim_sp.fin(sc_go(act, pc, s, Sc{0, 0, Nil{}, Nil{}}), id, own, log, oc, pcf, j)

def elim(r: Rw, st: Stp) -> Rw:
  match r:
    case Sp{id, w, +act, own, log, oc}:
      match st:
        case Stp{+pc, pcf, +s, j}:
          elim_sp.go(hit(act, pc, s), id, w, act, own, log, oc, Stp{pc, pcf, s, j})
    case Dn{id, co}:
      Dn{id, co}

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

def st6b(asg: Asg, +id: U32, +pc: U32, +pcf: U32, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, +n: U32, l: List<&2, Pv>, +nin: U32, il: List<&2, U32>, p: U32, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>) -> P1:
  match asg:
    case Asg{+s, +rp}:
      st7(Stp{pc, pcf, s, n}, Pv{pc, pcf, List.append(&2, T.Term, rp, own), log, oc, id}, n, l, (nin + U32.from_nat(List.length(&2, T.Term, s)) : U32), List.append(&2, U32, List.reverse(&2, U32, cols_of(s)), il), p, rows, wt, bk, dn, gather(cols_of(s), Array.swap(List<&2, U32>, ci, pc, Nil{}), Nil{}))

def st6(+id: U32, +pc: U32, +pcf: U32, +rest: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match pivs:
    case Pl{+n, l, +nin, il, +p}:
      st6b(asg_go(rest, (p + nin : U32), Nil{}, Nil{}), id, pc, pcf, own, log, oc, n, l, nin, il, p, rows, wt, bk, ci, dn)

def st5b(+id: U32, h: T.Term, rest: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match h:
    case T.Term{pc, pcf}:
      st6(id, pc, pcf, rest, own, log, oc, rows, wt, bk, ci, dn, pivs)

def st5a(+id: U32, act: List<&2, T.Term>, own: List<&2, T.Term>, log: List<&2, Lg>, oc: List<&2, T.Term>, rows: Array<Rw>, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match act:
    case Nil{}:
      P1{rows, wt, bk, ci, dn, pivs, 1}
    case h <> rest:
      st5b(id, h, rest, own, log, oc, rows, wt, bk, ci, dn, pivs)

def st5(+id: U32, r: Array<Rw> & Rw, wt: Array<U32>, bk: Array<List<&2, U32>>, ci: Array<List<&2, U32>>, dn: List<&2, Rw>, pivs: Pl) -> P1:
  match r:
    case Tuple{rows, row}:
      match row:
        case Sp{rid, w, act, own, log, oc}:
          st5a(id, act, own, log, oc, rows, wt, bk, ci, dn, pivs)
        case Dn{rid, co}:
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

def init_sparse(+id: U32, +act: List<&2, T.Term>, own: List<&2, T.Term>, oc: List<&2, T.Term>, st: IN) -> IN:
  match st:
    case IN{rows, wt, bk, ci, dn}:
      +w = U32.from_nat(List.length(&2, T.Term, act))
      IN{Array.set(Rw, rows, id, Sp{id, w, act, own, Nil{}, oc}), Array.set(U32, wt, id, w), bk_push_if(U32.is_ne(w, 0), bk, w, id), ci_add(act, id, ci), dn}

def init_dense(id: U32, co: G.Vec, st: IN) -> IN:
  match st:
    case IN{rows, wt, bk, ci, dn}:
      IN{rows, wt, bk, ci, Dn{id, co} <> dn}

def init_row3(dense: Bool, +id: U32, +ts: List<&2, T.Term>, +cols: List<&2, T.Term>, +l: U32, +p: U32, zero: G.Vec, nw: U32, st: IN) -> IN:
  match dense:
    case True{}:
      init_dense(id, fold_terms(cols, zero, nw), st)
    case False{}:
      +lim = (l - p : U32)
      init_sparse(id, List.reverse(&2, T.Term, ts_flt(ts, lim, True{}, Nil{})), ts_pos(ts_flt(ts, lim, False{}, Nil{}), lim), ts, st)

def init_row2(+ts: List<&2, T.Term>, cols: List<&2, T.Term>, +id: U32, +l: U32, +p: U32, zero: G.Vec, nw: U32, st: IN) -> IN:
  init_row3(is_dense(U32.from_nat(List.length(&2, T.Term, ts)), l), id, ts, cols, l, p, zero, nw, st)

def init_row(r: T.Row, +id: U32, +l: U32, +p: U32, zero: G.Vec, nw: U32, st: IN) -> IN:
  match r:
    case T.Row{+cols, rhs}:
      init_row2(tsort(cols), cols, id, l, p, zero, nw, st)

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
# 7. The Plan (RFC 5.4.2.2: symbol-independent part of the solve) and phase 2
# ===========================================================================
# Everything the solver does to the symbols is a linear combination of the input rhs symbols with GF(256)
# coefficients that depend only on the coefficient matrix.  `Solver.plan` runs phase 1, the coefficient side of the
# materialisation, and phase 2 on coefficients only, and records the combinations in a Plan; `Solver.apply` replays
# them on symbols (section 9):
#   pivots   R_k   = rhs[id_k] + sum g * R_j                              (j < k pivots, log entries)
#   tail     R'_i  = rhs[id_i] + sum g * R_k                              (leftover rows and corrected dense rows)
#   inactive C[col] = sum f * R'_i                                        (the dense tail solved: rows of M = A^-1)
#   pivots   C[pc_k] = finv_k * (rhs[id_k] + sum f * C[c])               (forward substitution, original equations)
# The dense tail system is solved ONCE with the rhs replaced by unit vectors (one octet per tail row), so the
# result of the Gauss-Jordan is the matrix M itself.
type PP is Data:
  PP{id: U32, pc: U32, finv: U32, log: List<&2, Lg>, oc: List<&2, T.Term>}   # oc = original terms WITHOUT the pivot column

type TR is Data:
  TR{id: U32, log: List<&2, Lg>}                                            # tail row: input row id + log over the pivots

type TC is Data:
  TC{col: U32, ts: List<&2, T.Term>}                                        # inactive column: Term{tail row index, coef}

# l = columns, nrows = number of input rows (= rhs symbols apply needs), npiv / ntr = lengths of pivs / trs
type Plan is Data:
  Plan{l: U32, nrows: U32, npiv: U32, ntr: U32, pivs: List<&2, PP>, trs: List<&2, TR>, tail: List<&2, TC>}

def pivcols(pivs: List<&2, Pv>, acc: List<&2, U32>) -> List<&2, U32>:
  match pivs:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case Pv{pc, pcf, own, log, oc, id}:
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

# nonzero octets of a Vec (given as its word list): octet index i.. -> Term{index, coef}
def tc_add(+c: U32, +i: U32, acc: List<&2, T.Term>) -> List<&2, T.Term>:
  match c:
    case 0:
      acc
    case _:
      T.Term{i, c} <> acc

def tc_word(+w: U32, +i: U32, acc: List<&2, T.Term>) -> List<&2, T.Term>:
  tc_add(byte_of(w, 3), (i + 3 : U32), tc_add(byte_of(w, 2), (i + 2 : U32), tc_add(byte_of(w, 1), (i + 1 : U32), tc_add(byte_of(w, 0), i, acc))))

# ---- the pivots as PP: split off the pivot column's coefficient of the original equation -----------------------
type Sx is Data:
  Sx{f: U32, rest: List<&2, T.Term>}

def sx_step(isp: Bool, c: U32, f: U32, f0: U32, rest: List<&2, T.Term>) -> Sx:
  match isp:
    case True{}:
      Sx{f, rest}
    case False{}:
      Sx{f0, T.Term{c, f} <> rest}

def oc_split(ts: List<&2, T.Term>, +pc: U32, st: Sx) -> Sx:
  match ts st:
    case Nil{} _:
      st
    case T.Term{+c, f} <> t Sx{f0, rest}:
      oc_split(t, pc, sx_step(U32.is_eq(c, pc), c, f, f0, rest))

def pp_fin(+id: U32, +pc: U32, log: List<&2, Lg>, sx: Sx) -> PP:
  match sx:
    case Sx{f, rest}:
      PP{id, pc, G.inv(f), log, rest}

def pp_of(pvs: List<&2, Pv>) -> List<&2, PP>:
  match pvs:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case Pv{+pc, pcf, own, log, oc, id}:
          pp_fin(id, pc, log, oc_split(oc, pc, Sx{0, Nil{}})) <> pp_of(t)

# ---- driver of the plan side ------------------------------------------------------------------------------
# cost knobs of the tail Gauss-Jordan (PAR() = 0: sequential, see docs/perf.md)
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

# log entry g * (pivot k), omitted when g = 0
def lg_push(+g: U32, k: U32, log: List<&2, Lg>) -> List<&2, Lg>:
  match g:
    case 0:
      log
    case _:
      Lg{g, k} <> log

# ---- arena helpers shared by the plan (coefficients) and the apply (symbols) ------------------------------------
def TAB_MIN() -> U32:
  8

# R_k = rhs[id_k] + sum g * R_j  (dst = the pivot's slot, already holding rhs[id_k])
def ap.log(lg: List<&2, Lg>, +tab: Bool, +w: Nat, +wu: U32, +dst: U32, +ar: U32, a: Array<U32>) -> Array<U32>:
  match lg:
    case Nil{}:
      a
    case Con{h, t}:
      match h:
        case Lg{g, j}:
          ap.log(t, tab, w, wu, dst, ar, F.Flat.axpy(g, tab, w, dst, (ar + j * wu : U32), a))

# the arena: table (if tab) and the rhs symbols copied in; returns the finished array
def ap.init(+tab: Bool, a: Array<U32>) -> Array<U32>:
  match tab:
    case True{}:
      F.Flat.table(a)
    case False{}:
      a

def ap.tbsz(+tab: Bool) -> U32:
  match tab:
    case True{}:
      65536
    case False{}:
      0

# ---------------------------------------------------------------------------
# Coefficient side of the plan on a flat arena (the materialisation of RFC 5.4.2.2 and phase 2): coefficients over the tail
# columns Ci are packed 4 octets per word, like symbols, and handled by the same slice kernels (src/flat.bend).  One Array<U32>:
#   [product table 64K, only if tab] [V_k: npiv pivot rows of nwd words (= coefficients over Ci)] [G: m tail rows of
#   wg = nwd + nwm words: coefficients over Ci | unit vector e_i] [dense rows' full-width coefficients: ndn rows of nw words]
#   [pivot flag per tail row: m] [row of G that pivots column c: n]
# V_k = pack(own_k) + sum g V_j over the log; tail rows are the leftover sparse rows (same formula) and the dense rows (their entries
# at Ci, corrected for every pivot: row -= g_k V_k with g_k = orig[pc_k] / pcf_k, recorded in the log for Solver.apply); then
# Gauss-Jordan on G (coefficients | unit vectors), so the unit part of the row that pivots column c is row c of M = A_tail^-1.
# ---------------------------------------------------------------------------

# own terms Term{position, coef}: row[octet position] ^= coef (at slot base..)
def p2.xo(own: List<&2, T.Term>, +base: U32, a: Array<U32>) -> Array<U32>:
  match own:
    case Nil{}:
      a
    case Con{t, rest}:
      match t:
        case T.Term{+pos, f}:
          p2.xo(rest, base, F.Flat.wxor((base + U32.shrn(pos, 2n) : U32), byte_word(f, U32.and(pos, 3)), a))

# a row = pack(own) + sum g * V_j (V_j at slot pvb + j * nwd), the destination row starts zero
def p2.row(own: List<&2, T.Term>, log: List<&2, Lg>, +dst: U32, +pvb: U32, +tab: Bool, +w: Nat, +nwd: U32, a: Array<U32>) -> Array<U32>:
  ap.log(log, tab, w, nwd, dst, pvb, p2.xo(own, dst, a))

def p2.pvs(pvs: List<&2, Pv>, +k: U32, +tab: Bool, +w: Nat, +nwd: U32, +pvb: U32, a: Array<U32>) -> Array<U32>:
  match pvs:
    case Nil{}:
      a
    case Con{pv, t}:
      match pv:
        case Pv{pc, pcf, own, log, oc, id}:
          p2.pvs(t, (k + 1 : U32), tab, w, nwd, pvb, p2.row(own, log, (pvb + k * nwd : U32), pvb, tab, w, nwd, a))

type Pt is Type:
  Pt{a: Array<U32>, trs: List<&2, TR>}

# octet i of the unit part (slot ub = start of the unit part of the row) := 1
def p2.unit(+i: U32, +ub: U32, a: Array<U32>) -> Array<U32>:
  F.Flat.wxor((ub + U32.shrn(i, 2n) : U32), byte_word(1, U32.and(i, 3)), a)

# leftover sparse rows -> tail rows i, i+1, ...
def p2.lrs(rs: List<&2, Rw>, +i: U32, +tab: Bool, +w: Nat, +nwd: U32, +wg: U32, +gb: U32, +pvb: U32, st: Pt) -> Pt:
  match rs st:
    case Nil{} _:
      st
    case Sp{rid, w0, act, own, +log, oc} <> t Pt{a, trs}:
      p2.lrs(t, (i + 1 : U32), tab, w, nwd, wg, gb, pvb, Pt{p2.unit(i, (gb + i * wg + nwd : U32), p2.row(own, log, (gb + i * wg : U32), pvb, tab, w, nwd, a)), TR{rid, log} <> trs})
    case Dn{rid, co} <> t Pt{a, trs}:
      p2.lrs(t, i, tab, w, nwd, wg, gb, pvb, Pt{a, trs})

# dense rows: full-width coefficients into the arena
def p2.dnput(dn: List<&2, Rw>, +d: U32, +nw: U32, +dnb: U32, a: Array<U32>) -> Array<U32>:
  match dn:
    case Nil{}:
      a
    case Con{r, t}:
      match r:
        case Sp{rid, w0, act, own, log, oc}:
          p2.dnput(t, d, nw, dnb, a)
        case Dn{rid, co}:
          p2.dnput(t, (d + 1 : U32), nw, dnb, F.Flat.put.go(co, nw, (dnb + d * nw : U32), a))

# the entries of the dense row (slot dnrow) at the columns Ci -> positions 0.. of the tail row at slot grow
def p2.gather.f(+c: U32, +pos: U32, +grow: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, wd) = rd
  F.Flat.wxor((grow + U32.shrn(pos, 2n) : U32), byte_word(byte_of(wd, U32.and(c, 3)), U32.and(pos, 3)), a)

def p2.gather(ci: List<&2, U32>, +pos: U32, +dnrow: U32, +grow: U32, a: Array<U32>) -> Array<U32>:
  match ci:
    case Nil{}:
      a
    case Con{+c, t}:
      p2.gather(t, (pos + 1 : U32), dnrow, grow, p2.gather.f(c, pos, grow, Array.get(U32, a, (dnrow + U32.shrn(c, 2n) : U32))))

type Dd is Type:
  Dd{a: Array<U32>, log: List<&2, Lg>}

def p2.dp1(+pc: U32, +pcf: U32, +k: U32, +grow: U32, +pvb: U32, +tab: Bool, +w: Nat, +nwd: U32, log0: List<&2, Lg>, rd: Array<U32> & U32) -> Dd:
  (a, wd) = rd
  +g = G.div(byte_of(wd, U32.and(pc, 3)), pcf)
  Dd{F.Flat.axpy(g, tab, w, grow, (pvb + k * nwd : U32), a), lg_push(g, k, log0)}

# row -= g_k V_k for every pivot k, g_k = orig[pc_k] / pcf_k
def p2.dpiv(pvs: List<&2, Pv>, +k: U32, +dnrow: U32, +grow: U32, +pvb: U32, +tab: Bool, +w: Nat, +nwd: U32, st: Dd) -> Dd:
  match pvs st:
    case Nil{} _:
      st
    case Pv{+pc, pcf, own, log, oc, id} <> t Dd{a, log0}:
      p2.dpiv(t, (k + 1 : U32), dnrow, grow, pvb, tab, w, nwd, p2.dp1(pc, pcf, k, grow, pvb, tab, w, nwd, log0, Array.get(U32, a, (dnrow + U32.shrn(pc, 2n) : U32))))

def p2.dfin(+rid: U32, +i: U32, +ub: U32, dd: Dd, trs: List<&2, TR>) -> Pt:
  match dd:
    case Dd{a, log}:
      Pt{p2.unit(i, ub, a), TR{rid, log} <> trs}

# dense row d -> tail row i
def p2.dense(dn: List<&2, Rw>, +d: U32, +i: U32, +ci: List<&2, U32>, +ords: List<&2, Pv>, +tab: Bool, +w: Nat, +nwd: U32, +wg: U32, +gb: U32, +pvb: U32, +dnb: U32, +nw: U32, st: Pt) -> Pt:
  match dn st:
    case Nil{} _:
      st
    case Sp{rid, w0, act, own, log, oc} <> t Pt{a, trs}:
      p2.dense(t, d, i, ci, ords, tab, w, nwd, wg, gb, pvb, dnb, nw, Pt{a, trs})
    case Dn{rid, co} <> t Pt{a, trs}:
      p2.dense(t, (d + 1 : U32), (i + 1 : U32), ci, ords, tab, w, nwd, wg, gb, pvb, dnb, nw, p2.dfin(rid, i, (gb + i * wg + nwd : U32), p2.dpiv(ords, 0, (dnb + d * nw : U32), (gb + i * wg : U32), pvb, tab, w, nwd, Dd{p2.gather(ci, 0, (dnb + d * nw : U32), (gb + i * wg : U32), a), Nil{}}), trs))

# ---- Gauss-Jordan on G --------------------------------------------------------------------------------------
type Fp is Type:
  Fp{a: Array<U32>, row: U32}

type Gr is Type:
  Gr{a: Array<U32>, ok: Bool}

# first tail row (in order) that is not a pivot yet and has a nonzero octet in column c; m = none
def p2.fs.f2(+r: U32, +row: U32, +m: U32, +c: U32, +fl: U32, rd: Array<U32> & U32) -> Fp:
  (a, wd) = rd
  +o = byte_of(wd, U32.and(c, 3))
  Fp{a, pick_u(band(band(U32.is_eq(fl, 0), U32.is_ne(o, 0)), U32.is_eq(row, m)), r, row)}

def p2.fs.f1(+r: U32, +row: U32, +m: U32, +c: U32, +gcol: U32, +wg: U32, rd: Array<U32> & U32) -> Fp:
  (a, fl) = rd
  p2.fs.f2(r, row, m, c, fl, Array.get(U32, a, (gcol + r * wg : U32)))

def p2.find(+n: Nat, +r: U32, +c: U32, +m: U32, +gcol: U32, +wg: U32, +pf: U32, st: Fp) -> Fp:
  match n st:
    case 0n _:
      st
    case 1n+q Fp{a, row}:
      p2.find(q, (r + 1 : U32), c, m, gcol, wg, pf, p2.fs.f1(r, row, m, c, gcol, wg, Array.get(U32, a, (pf + r : U32))))

# scale the pivot row so that its octet at column c is 1
def p2.nrm.f(+row: U32, +c: U32, +gb: U32, +wg: U32, +tab: Bool, +w: Nat, rd: Array<U32> & U32) -> Array<U32>:
  (a, wd) = rd
  F.Flat.scale(G.inv(byte_of(wd, U32.and(c, 3))), tab, w, (gb + row * wg : U32), a)

def p2.nrm(+row: U32, +c: U32, +gb: U32, +wg: U32, +tab: Bool, +w: Nat, a: Array<U32>) -> Array<U32>:
  p2.nrm.f(row, c, gb, wg, tab, w, Array.get(U32, a, (gb + row * wg + U32.shrn(c, 2n) : U32)))

# eliminate column c from every other row: row2 ^= f * pivot row
def p2.el.keep(rd: Array<U32> & U32) -> Array<U32>:
  (a, wd) = rd
  a

def p2.el.go(+r2: U32, +row: U32, +c: U32, +gb: U32, +wg: U32, +tab: Bool, +w: Nat, rd: Array<U32> & U32) -> Array<U32>:
  (a, wd) = rd
  F.Flat.axpy(byte_of(wd, U32.and(c, 3)), tab, w, (gb + r2 * wg : U32), (gb + row * wg : U32), a)

def p2.el.f(+isp: Bool, +r2: U32, +row: U32, +c: U32, +gb: U32, +wg: U32, +tab: Bool, +w: Nat, rd: Array<U32> & U32) -> Array<U32>:
  match isp:
    case True{}:
      p2.el.keep(rd)
    case False{}:
      p2.el.go(r2, row, c, gb, wg, tab, w, rd)

def p2.elim(+n: Nat, +r2: U32, +row: U32, +c: U32, +gb: U32, +wg: U32, +tab: Bool, +w: Nat, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      p2.elim(q, (r2 + 1 : U32), row, c, gb, wg, tab, w, p2.el.f(U32.is_eq(r2, row), r2, row, c, gb, wg, tab, w, Array.get(U32, a, (gb + r2 * wg + U32.shrn(c, 2n) : U32))))

def p2.col2(go: Bool, +row: U32, +c: U32, +m: U32, +tab: Bool, +w: Nat, +wg: U32, +gb: U32, +pf: U32, +pcb: U32, a: Array<U32>) -> Gr:
  match go:
    case True{}:
      Gr{p2.elim(U32.to_nat(m), 0, row, c, gb, wg, tab, w, Array.set(U32, Array.set(U32, p2.nrm(row, c, gb, wg, tab, w, a), (pf + row : U32), (c + 1 : U32)), (pcb + c : U32), row)), True{}}
    case False{}:
      Gr{a, False{}}

def p2.col(+c: U32, +m: U32, +tab: Bool, +w: Nat, +wg: U32, +gb: U32, +pf: U32, +pcb: U32, f: Fp) -> Gr:
  match f:
    case Fp{a, +row}:
      p2.col2(U32.is_lt(row, m), row, c, m, tab, w, wg, gb, pf, pcb, a)

# columns 0..n-1 in turn; stops (ok = False) at the first column without a pivot: rank < n
def p2.cols(+k: Nat, +c: U32, +m: U32, +tab: Bool, +w: Nat, +wg: U32, +gb: U32, +pf: U32, +pcb: U32, st: Gr) -> Gr:
  match k st:
    case 0n _:
      st
    case 1n+q Gr{a, ok}:
      match ok:
        case True{}:
          p2.cols(q, (c + 1 : U32), m, tab, w, wg, gb, pf, pcb, p2.col(c, m, tab, w, wg, gb, pf, pcb, p2.find(U32.to_nat(m), 0, c, m, (gb + U32.shrn(c, 2n) : U32), wg, pf, Fp{a, m})))
        case False{}:
          Gr{a, False{}}

# ---- rows of M (unit parts of the pivot rows) -> TC list ------------------------------------------------------
type Sq is Type:
  Sq{a: Array<U32>, acc: List<&2, T.Term>}

type Tq is Type:
  Tq{a: Array<U32>, out: List<&2, TC>}

def p2.sc1(+j: U32, acc: List<&2, T.Term>, rd: Array<U32> & U32) -> Sq:
  (a, wd) = rd
  Sq{a, tc_word(wd, (j * 4 : U32), acc)}

def p2.sc(+n: Nat, +j: U32, +ub: U32, st: Sq) -> Sq:
  match n st:
    case 0n _:
      st
    case 1n+q Sq{a, acc}:
      p2.sc(q, (j + 1 : U32), ub, p2.sc1(j, acc, Array.get(U32, a, (ub + j : U32))))

def p2.tc2(+col: U32, out: List<&2, TC>, sq: Sq) -> Tq:
  match sq:
    case Sq{a, acc}:
      Tq{a, TC{col, acc} <> out}

def p2.tc1(+col: U32, +nwm: Nat, +nwd: U32, +wg: U32, +gb: U32, out: List<&2, TC>, rd: Array<U32> & U32) -> Tq:
  (a, +row) = rd
  p2.tc2(col, out, p2.sc(nwm, 0, (gb + row * wg + nwd : U32), Sq{a, Nil{}}))

def p2.tc(ci: List<&2, U32>, +c: U32, +nwm: Nat, +nwd: U32, +wg: U32, +gb: U32, +pcb: U32, st: Tq) -> Tq:
  match ci st:
    case Nil{} _:
      st
    case Con{+col, t} Tq{a, out}:
      p2.tc(t, (c + 1 : U32), nwm, nwd, wg, gb, pcb, p2.tc1(col, nwm, nwd, wg, gb, out, Array.get(U32, a, (pcb + c : U32))))

def p2.fin2(tq: Tq, +l: U32, +nrows: U32, +np: U32, +m: U32, ords: List<&2, Pv>, trs: List<&2, TR>) -> Maybe<&2, Plan>:
  match tq:
    case Tq{a, out}:
      Some{Plan{l, nrows, np, m, pp_of(ords), List.reverse(&2, TR, trs), out}}

# the Gauss-Jordan result: None if some column has no pivot, else the TC list
def p2.fin1(gr: Gr, +n: U32, ci: List<&2, U32>, +nwm: Nat, +nwd: U32, +wg: U32, +gb: U32, +pcb: U32, +l: U32, +nrows: U32, +np: U32, +m: U32, ords: List<&2, Pv>, trs: List<&2, TR>) -> Maybe<&2, Plan>:
  match gr:
    case Gr{a, ok}:
      match ok:
        case True{}:
          p2.fin2(p2.tc(ci, 0, nwm, nwd, wg, gb, pcb, Tq{a, Nil{}}), l, nrows, np, m, ords, trs)
        case False{}:
          None{}

def p2.fin0(pt: Pt, +n: U32, +ci: List<&2, U32>, +nwm: Nat, +nwd: U32, +wg: U32, +gb: U32, +pf: U32, +pcb: U32, +m: U32, +tab: Bool, +l: U32, +nrows: U32, +np: U32, ords: List<&2, Pv>) -> Maybe<&2, Plan>:
  match pt:
    case Pt{a, trs}:
      p2.fin1(p2.cols(U32.to_nat(n), 0, m, tab, U32.to_nat(wg), wg, gb, pf, pcb, Gr{a, True{}}), n, ci, nwm, nwd, wg, gb, pcb, l, nrows, np, m, ords, trs)

# number of leftover sparse rows / dense rows
def p2.count_sp(rs: List<&2, Rw>, +acc: U32) -> U32:
  match rs:
    case Nil{}:
      acc
    case Con{r, t}:
      match r:
        case Sp{rid, w0, act, own, log, oc}:
          p2.count_sp(t, (acc + 1 : U32))
        case Dn{rid, co}:
          p2.count_sp(t, acc)

def p2.count_dn(rs: List<&2, Rw>, +acc: U32) -> U32:
  match rs:
    case Nil{}:
      acc
    case Con{r, t}:
      match r:
        case Sp{rid, w0, act, own, log, oc}:
          p2.count_dn(t, acc)
        case Dn{rid, co}:
          p2.count_dn(t, (acc + 1 : U32))

# the arena machinery switches to the product table when there are enough word products to repay its 1.3 ms
def p2.use_tab(+np: U32, +n: U32, +wg: U32) -> Bool:
  U32.is_ge(((np + n) * wg : U32), 16384)

# layout and driver: nleft leftover rows then ndn dense rows are the tail rows 0..m-1
def p2.run(+ci: List<&2, U32>, +rs: List<&2, Rw>, +dn: List<&2, Rw>, +ords: List<&2, Pv>, +l: U32, +nrows: U32, +nw: U32, +n: U32, +np: U32, +nleft: U32, +ndn: U32, +tab: Bool) -> Maybe<&2, Plan>:
  +nwd = nwords(n)
  +m = (nleft + ndn : U32)
  +nwm = nwords(m)
  +wg = (nwd + nwm : U32)
  +pvb = ap.tbsz(tab)
  +gb = (pvb + np * nwd : U32)
  +dnb = (gb + m * wg : U32)
  +pf = (dnb + ndn * nw : U32)
  +pcb = (pf + m : U32)
  p2.fin0(p2.dense(dn, 0, nleft, ci, ords, tab, U32.to_nat(nwd), nwd, wg, gb, pvb, dnb, nw, p2.lrs(rs, 0, tab, U32.to_nat(nwd), nwd, wg, gb, pvb, Pt{p2.dnput(dn, 0, nw, dnb, p2.pvs(ords, 0, tab, U32.to_nat(nwd), nwd, pvb, ap.init(tab, Array.new(U32, clog((pcb + n : U32)), 0)))), Nil{}})), n, ci, U32.to_nat(nwm), nwd, wg, gb, pf, pcb, m, tab, l, nrows, np, ords)

def phase2.go(+ci: List<&2, U32>, rs: List<&2, Rw>, +dn: List<&2, Rw>, +pivs: List<&2, Pv>, +l: U32, +nrows: U32, +nw: U32) -> Maybe<&2, Plan>:
  +n = U32.from_nat(List.length(&2, U32, ci))
  +ords = List.reverse(&2, Pv, pivs)
  +np = U32.from_nat(List.length(&2, Pv, ords))
  +rs2 = rs
  +nleft = p2.count_sp(rs2, 0)
  +ndn = p2.count_dn(dn, 0)
  p2.run(ci, rs2, dn, ords, l, nrows, nw, n, np, nleft, ndn, p2.use_tab(np, n, (nwords(n) + nwords((nleft + ndn : U32)) : U32)))

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

def phase2(rs: List<&2, Rw>, dn: List<&2, Rw>, +pivs: List<&2, Pv>, il: List<&2, U32>, +p: U32, +l: U32, +nrows: U32, +nw: U32) -> Maybe<&2, Plan>:
  +perm = perm_cols(U32.to_nat(p), (l - p : U32))
  +dyn = List.reverse(&2, U32, il)
  phase2.go(phase2.cl2(perm, dyn, List.append(&2, U32, pivcols(pivs, Nil{}), List.append(&2, U32, dyn, perm)), l), rs, dn, pivs, l, nrows, nw)

# ===========================================================================
# 8. Phase 1 -> rows left over (arr_rows) and the plan driver
# ===========================================================================
def keep_live.go(live: Bool, x: Rw, acc: List<&2, Rw>) -> List<&2, Rw>:
  match live:
    case True{}:
      x <> acc
    case False{}:
      acc

def keep_live(+x: Rw, acc: List<&2, Rw>) -> List<&2, Rw>:
  keep_live.go(is_live(x), x, acc)

# the rows that are neither pivots nor dense: Sp rows left in the table
def arr_rows(a: Array<Rw>, acc: List<&2, Rw>) -> List<&2, Rw>:
  match a:
    case ALeaf{x}:
      keep_live(x, acc)
    case ANode{xs, ys}:
      arr_rows(xs, arr_rows(ys, acc))

def phase1_fin(st: P1, +l: U32, +nrows: U32, +nw: U32) -> Maybe<&2, Plan>:
  match st:
    case P1{rows, wt, bk, ci, dn, pivs, done}:
      match pivs:
        case Pl{n, pl, nin, il, p}:
          phase2(arr_rows(rows, Nil{}), dn, pl, il, p, l, nrows, nw)

def plan_go(+l: U32, +p: U32, +nrows: U32, rows: List<&2, T.Row>) -> Maybe<&2, Plan>:
  +nw = nwords(l)
  phase1_fin(phase1(l, p, nrows, rows, nw), l, nrows, nw)

# The symbol-independent part of the inactivation solve (RFC 5.4.2.2): only the coefficients (`cols`) of the rows are
# looked at, the rhs symbols are ignored (callers may pass G.VNil{}).  p = number of permanently inactive columns
# (the last p columns).  None if rank < l.  Row i of the system is rhs symbol i of Solver.apply.
def Solver.plan(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> Maybe<&2, Plan>:
  plan_go(l, p, U32.from_nat(List.length(&2, T.Row, rows)), rows)

# number of rhs symbols (= rows of the system) Solver.apply expects, and the number of columns of the solution
def Solver.plan_rows(plan: Plan) -> U32:
  match plan:
    case Plan{l, nrows, npiv, ntr, pivs, trs, tail}:
      nrows

def Solver.plan_cols(plan: Plan) -> U32:
  match plan:
    case Plan{l, nrows, npiv, ntr, pivs, trs, tail}:
      l

# ===========================================================================
# 9. Solver.apply: the plan replayed on symbols, on ONE flat Array<U32> (the symbol arena)
# ===========================================================================
# All symbols of an apply live in a single `Array<U32>` (4 octets per slot, wu = words per symbol, symbol s of a region at
# slot base + s * wu); every step is a tail-recursive loop over slices (src/flat.bend; docs/profile.md R3).  The plan stays
# pure data (lists, no Array): apply builds the arena, so a plan is still duplicable and reusable.  Layout, in slots:
#   [product table 64K, only if tab] [rhs symbols by row id: nrows] [pivot symbols R_k: npiv] [tail rows R'_i: ntr]
#   [solution C by column: l] [one scratch symbol]
# The table T[(c << 8) | b] = c * b makes a word product four lookups (2.9 ns/word vs 8.6 for the SWAR loop); building it takes
# about 1.3 ms, so symbols below TAB_MIN() words (T < 32 octets) use the SWAR loop instead (tab = False); measured K = 1000:
# T = 64: 4 ms with the table vs 6 without, T = 256: 11 vs 16, T = 1024: 35 vs 61, T = 16: 3 vs 2.

# pivots, in selection order: copy rhs[id], add the log entries
def ap.pivs(pvs: List<&2, PP>, +k: U32, +tab: Bool, +w: Nat, +wu: U32, +ra: U32, +ar: U32, a: Array<U32>) -> Array<U32>:
  match pvs:
    case Nil{}:
      a
    case Con{pv, t}:
      match pv:
        case PP{id, pc, finv, log, oc}:
          ap.pivs(t, (k + 1 : U32), tab, w, wu, ra, ar, ap.log(log, tab, w, wu, (ar + k * wu : U32), ar, F.Flat.cp.loop(w, 0, (ar + k * wu : U32), (ra + id * wu : U32), a)))

# tail rows: R'_i = rhs[id_i] + sum g * R_k
def ap.trs(trs: List<&2, TR>, +i: U32, +tab: Bool, +w: Nat, +wu: U32, +ra: U32, +ar: U32, +rt: U32, a: Array<U32>) -> Array<U32>:
  match trs:
    case Nil{}:
      a
    case Con{tr, t}:
      match tr:
        case TR{id, log}:
          ap.trs(t, (i + 1 : U32), tab, w, wu, ra, ar, rt, ap.log(log, tab, w, wu, (rt + i * wu : U32), ar, F.Flat.cp.loop(w, 0, (rt + i * wu : U32), (ra + id * wu : U32), a)))

# inactive columns: C[col] = sum f * R'_i  (the dense tail solved: a row of M = A^-1 per column)
def ap.tail(tail: List<&2, TC>, +tab: Bool, +w: Nat, +wu: U32, +rt: U32, +ca: U32, a: Array<U32>) -> Array<U32>:
  match tail:
    case Nil{}:
      a
    case Con{tc, t}:
      match tc:
        case TC{col, ts}:
          ap.tail(t, tab, w, wu, rt, ca, F.Flat.fold(ts, tab, w, wu, (ca + col * wu : U32), rt, a))

# forward substitution through the original equations: C[pc_k] = finv_k * (rhs[id_k] + sum f * C[c])
def ap.p3(pvs: List<&2, PP>, +tab: Bool, +w: Nat, +wu: U32, +ra: U32, +ca: U32, a: Array<U32>) -> Array<U32>:
  match pvs:
    case Nil{}:
      a
    case Con{pv, t}:
      match pv:
        case PP{id, +pc, finv, log, oc}:
          ap.p3(t, tab, w, wu, ra, ca, F.Flat.scale(finv, tab, w, (ca + pc * wu : U32), F.Flat.fold.go(oc, tab, w, wu, (ca + pc * wu : U32), ca, F.Flat.cp.loop(w, 0, (ca + pc * wu : U32), (ra + id * wu : U32), a))))

def ap.run(+pivs: List<&2, PP>, trs: List<&2, TR>, tail: List<&2, TC>, +tab: Bool, +wu: U32, +ra: U32, +ar: U32, +rt: U32, +ca: U32, a: Array<U32>) -> Array<U32>:
  ap.p3(pivs, tab, U32.to_nat(wu), wu, ra, ca, ap.tail(tail, tab, U32.to_nat(wu), wu, rt, ca, ap.trs(trs, 0, tab, U32.to_nat(wu), wu, ra, ar, rt, ap.pivs(pivs, 0, tab, U32.to_nat(wu), wu, ra, ar, a))))

def ap.s3(+l: U32, +nrows: U32, +npiv: U32, +ntr: U32, +wu: U32, +tab: Bool, pivs: List<&2, PP>, trs: List<&2, TR>, tail: List<&2, TC>, rhs: List<&2, G.Vec>) -> F.Ar:
  +ra = ap.tbsz(tab)
  +ar = (ra + nrows * wu : U32)
  +rt = (ar + npiv * wu : U32)
  +ca = (rt + ntr * wu : U32)
  +sc = (ca + l * wu : U32)
  F.Ar{ap.run(pivs, trs, tail, tab, wu, ra, ar, rt, ca, F.Flat.fi_arr(F.Flat.lfill(rhs, wu, F.Fi{ra, ap.init(tab, Array.new(U32, clog((sc + wu : U32)), 0))}))), wu, ca, sc}

# word count of the first rhs symbol (all symbols have the same length), list handed back
type Pk is Data:
  Pk{wu: U32, xs: List<&2, G.Vec>}

def ap.peek(xs: List<&2, G.Vec>) -> Pk:
  match xs:
    case Nil{}:
      Pk{0, Nil{}}
    case Con{+h, t}:
      Pk{F.Flat.words(h), Con{h, t}}

def ap.s2(+l: U32, +nrows: U32, +npiv: U32, +ntr: U32, pivs: List<&2, PP>, trs: List<&2, TR>, tail: List<&2, TC>, pk: Pk) -> F.Ar:
  match pk:
    case Pk{+wu, xs}:
      ap.s3(l, nrows, npiv, ntr, wu, U32.is_ge(wu, TAB_MIN()), pivs, trs, tail, xs)

# ===========================================================================
# 9b. The plan as a FLAT PROGRAM (docs/scaling.md): the replay of section 9 compiled into an Array<U32> of 3-word instructions
# (w0 = kind + (c << 8), w1 = destination symbol, w2 = source symbol; symbols are numbered in the arena layout of section 9
# without the table: rhs rows, pivots, tail rows, solution C, scratch) and run by one tail-recursive interpreter.  Tasks of a parallel apply
# all read their own Array.clone of the program (a 0.1-0.5 ms copy; Array.fork would share one array in O(1) but is @unsafe and
# fails the proof gate; the plan's lists would be walked by every task through shared refcounted nodes, which does not scale), each over its own word slice of every symbol.
#   kind 0 d = s | 1 d ^= c*s | 2 d = c*s | 3 d = c*d | 4 d = 0
# ===========================================================================
type Em is Type:
  Em{a: Array<U32>, n: U32}

type Pm is Data:
  Pm{l: U32, nrows: U32, npiv: U32, ntr: U32, nin: U32}

type Pg is Type:
  Pg{p: Array<U32>, m: Pm}

def cn.lg(lg: List<&2, Lg>, +acc: U32) -> U32:
  match lg:
    case Nil{}:
      acc
    case Con{h, t}:
      cn.lg(t, (acc + 1 : U32))

def cn.tm(ts: List<&2, T.Term>, +acc: U32) -> U32:
  match ts:
    case Nil{}:
      acc
    case Con{h, t}:
      cn.tm(t, (acc + 1 : U32))

def cn.pivs(pvs: List<&2, PP>, +acc: U32) -> U32:
  match pvs:
    case Nil{}:
      acc
    case Con{pv, t}:
      match pv:
        case PP{id, pc, finv, log, oc}:
          cn.pivs(t, cn.tm(oc, cn.lg(log, (acc + 3 : U32))))

def cn.trs(trs: List<&2, TR>, +acc: U32) -> U32:
  match trs:
    case Nil{}:
      acc
    case Con{tr, t}:
      match tr:
        case TR{id, log}:
          cn.trs(t, cn.lg(log, (acc + 1 : U32)))

def cn.tail.add(+n: U32, +acc: U32) -> U32:
  match n:
    case 0:
      (acc + 1 : U32)
    case _:
      (acc + n : U32)

def cn.tail(tail: List<&2, TC>, +acc: U32) -> U32:
  match tail:
    case Nil{}:
      acc
    case Con{tc, t}:
      match tc:
        case TC{col, ts}:
          cn.tail(t, cn.tail.add(cn.tm(ts, 0), acc))

def em.put(+k: U32, +c: U32, +d: U32, +s: U32, st: Em) -> Em:
  match st:
    case Em{a, +n}:
      Em{Array.set(U32, Array.set(U32, Array.set(U32, a, n, (k + U32.shln(c, 8n) : U32)), (n + 1 : U32), d), (n + 2 : U32), s), (n + 3 : U32)}

def em.arr(st: Em) -> Array<U32>:
  match st:
    case Em{a, n}:
      a

# R_k += g * R_j for the log entries (dst symbol, pivot symbols from ar)
def pg.log(lg: List<&2, Lg>, +dst: U32, +ar: U32, st: Em) -> Em:
  match lg:
    case Nil{}:
      st
    case Con{h, t}:
      match h:
        case Lg{g, j}:
          pg.log(t, dst, ar, em.put(1, g, dst, (ar + j : U32), st))

def pg.pivs(pvs: List<&2, PP>, +k: U32, +ar: U32, st: Em) -> Em:
  match pvs:
    case Nil{}:
      st
    case Con{pv, t}:
      match pv:
        case PP{id, pc, finv, log, oc}:
          pg.pivs(t, (k + 1 : U32), ar, pg.log(log, (ar + k : U32), ar, em.put(0, 0, (ar + k : U32), id, st)))

def pg.trs(trs: List<&2, TR>, +i: U32, +ar: U32, +rt: U32, st: Em) -> Em:
  match trs:
    case Nil{}:
      st
    case Con{tr, t}:
      match tr:
        case TR{id, log}:
          pg.trs(t, (i + 1 : U32), ar, rt, pg.log(log, (rt + i : U32), ar, em.put(0, 0, (rt + i : U32), id, st)))

# d ^= f * (symbol base + i) for every term
def pg.fold(ts: List<&2, T.Term>, +dst: U32, +base: U32, st: Em) -> Em:
  match ts:
    case Nil{}:
      st
    case Con{t, rest}:
      match t:
        case T.Term{i, f}:
          pg.fold(rest, dst, base, em.put(1, f, dst, (base + i : U32), st))

# d = sum f * (symbol base + i) (an empty list zeroes d)
def pg.fold0(ts: List<&2, T.Term>, +dst: U32, +base: U32, st: Em) -> Em:
  match ts:
    case Nil{}:
      em.put(4, 0, dst, 0, st)
    case Con{t, rest}:
      match t:
        case T.Term{i, f}:
          pg.fold(rest, dst, base, em.put(2, f, dst, (base + i : U32), st))

def pg.tail(tail: List<&2, TC>, +rt: U32, +ca: U32, st: Em) -> Em:
  match tail:
    case Nil{}:
      st
    case Con{tc, t}:
      match tc:
        case TC{col, ts}:
          pg.tail(t, rt, ca, pg.fold0(ts, (ca + col : U32), rt, st))

def pg.p3(pvs: List<&2, PP>, +ca: U32, st: Em) -> Em:
  match pvs:
    case Nil{}:
      st
    case Con{pv, t}:
      match pv:
        case PP{id, +pc, finv, log, oc}:
          pg.p3(t, ca, em.put(3, finv, (ca + pc : U32), 0, pg.fold(oc, (ca + pc : U32), ca, em.put(0, 0, (ca + pc : U32), id, st))))

def pg.build(+nrows: U32, +npiv: U32, +ntr: U32, +nin: U32, +pivs: List<&2, PP>, trs: List<&2, TR>, tail: List<&2, TC>) -> Array<U32>:
  +ar = nrows
  +rt = (ar + npiv : U32)
  +ca = (rt + ntr : U32)
  em.arr(pg.p3(pivs, ca, pg.tail(tail, rt, ca, pg.trs(trs, 0, ar, rt, pg.pivs(pivs, 0, ar, Em{Array.new(U32, clog((nin * 3 + 3 : U32)), 0), 0})))))

def pg.of2(+l: U32, +nrows: U32, +npiv: U32, +ntr: U32, +pivs: List<&2, PP>, +trs: List<&2, TR>, +tail: List<&2, TC>) -> Pg:
  +nin = cn.tail(tail, cn.trs(trs, cn.pivs(pivs, 0)))
  Pg{pg.build(nrows, npiv, ntr, nin, pivs, trs, tail), Pm{l, nrows, npiv, ntr, nin}}

# compiles a plan (sequential; ~3 instructions per elimination)
def Solver.prog(plan: Plan) -> Pg:
  match plan:
    case Plan{l, nrows, npiv, ntr, pivs, trs, tail}:
      pg.of2(l, nrows, npiv, ntr, pivs, trs, tail)

# ---- interpreter -------------------------------------------------------------------------------------------------------
type Ip is Type:
  Ip{p: Array<U32>, a: Array<U32>}

def ip.op(+k: U32, +c: U32, +tab: Bool, +w: Nat, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  match k:
    case 0:
      F.Flat.cp.loop(w, 0, db, sb, a)
    case 1:
      F.Flat.axpy(c, tab, w, db, sb, a)
    case 2:
      F.Flat.axset(c, tab, w, db, sb, a)
    case 3:
      F.Flat.scale(c, tab, w, db, a)
    case _:
      F.Flat.zr.loop(w, 0, db, a)

def ip.exec(+x0: U32, +x1: U32, +x2: U32, +tab: Bool, +w: Nat, +wu: U32, +tb: U32, p: Array<U32>, a: Array<U32>) -> Ip:
  Ip{p, ip.op(U32.and(x0, 255), U32.shrn(x0, 8n), tab, w, (tb + x1 * wu : U32), (tb + x2 * wu : U32), a)}

def ip.f2(+i: U32, +tab: Bool, +w: Nat, +wu: U32, +tb: U32, a: Array<U32>, +x0: U32, +x1: U32, r: Array<U32> & U32) -> Ip:
  (p, x2) = r
  ip.exec(x0, x1, x2, tab, w, wu, tb, p, a)

def ip.f1(+i: U32, +tab: Bool, +w: Nat, +wu: U32, +tb: U32, a: Array<U32>, +x0: U32, r: Array<U32> & U32) -> Ip:
  (p, x1) = r
  ip.f2(i, tab, w, wu, tb, a, x0, x1, Array.get(U32, p, (i + 2 : U32)))

def ip.f0(+i: U32, +tab: Bool, +w: Nat, +wu: U32, +tb: U32, a: Array<U32>, r: Array<U32> & U32) -> Ip:
  (p, x0) = r
  ip.f1(i, tab, w, wu, tb, a, x0, Array.get(U32, p, (i + 1 : U32)))

def ip.step(+i: U32, +tab: Bool, +w: Nat, +wu: U32, +tb: U32, st: Ip) -> Ip:
  match st:
    case Ip{p, a}:
      ip.f0(i, tab, w, wu, tb, a, Array.get(U32, p, i))

def ip.run(+n: Nat, +i: U32, +tab: Bool, +w: Nat, +wu: U32, +tb: U32, st: Ip) -> Ip:
  match n:
    case 0n:
      st
    case 1n+q:
      ip.run(q, (i + 3 : U32), tab, w, wu, tb, ip.step(i, tab, w, wu, tb, st))

# one slice (or the whole block): the arena for symbols of wu words (table, rhs rows copied in), the program run on it
def ip.fin(st: Ip, +l: U32, +cs: U32, +wu: U32, +tb: U32) -> F.Ar:
  match st:
    case Ip{p, a}:
      F.Ar{a, wu, (tb + cs * wu : U32), (tb + (cs + l) * wu : U32)}

def ip.go(+m: Pm, +wu: U32, +tab: Bool, p: Array<U32>, rhs: List<&2, G.Vec>) -> F.Ar:
  match m:
    case Pm{l, nrows, npiv, ntr, nin}:
      +tb = ap.tbsz(tab)
      +nsym = (nrows + npiv + ntr + l + 1 : U32)
      ip.fin(ip.run(U32.to_nat(nin), 0, tab, U32.to_nat(wu), wu, tb, Ip{p, F.Flat.fi_arr(F.Flat.lfill(rhs, wu, F.Fi{tb, ap.init(tab, Array.new(U32, clog((tb + nsym * wu : U32)), 0))}))}), l, (nrows + npiv + ntr : U32), wu, tb)

def ip.s2(+m: Pm, p: Array<U32>, pk: Pk) -> F.Ar:
  match pk:
    case Pk{+wu, xs}:
      ip.go(m, wu, U32.is_ge(wu, TAB_MIN()), p, xs)

# the solved arena (as Solver.apply_arena) via the program, for the rhs symbols (or slices of them) `rhs`
def Solver.apply_prog(+m: Pm, p: Array<U32>, rhs: List<&2, G.Vec>) -> F.Ar:
  ip.s2(m, p, ap.peek(rhs))


# Replays a plan on the rhs symbols (`rhs` = one symbol per row of the system the plan was made from, same order, exactly
# Solver.plan_rows(plan) of them, all of the same length) and returns the solved ARENA (flat symbols, see src/flat.bend)
# instead of a list of trees: C[0..l-1] are the symbols at slots ca + c * wu.  For callers that go on computing with the
# solution (the codec re-encodes from it) without converting to trees and back.  The plan is compiled to a flat program first
# (section 9b; 2 ms at K = 1000) and interpreted.
def apply.arena2(pg: Pg, rhs: List<&2, G.Vec>) -> F.Ar:
  match pg:
    case Pg{p, m}:
      Solver.apply_prog(m, p, rhs)

def Solver.apply_arena(plan: Plan, rhs: List<&2, G.Vec>) -> F.Ar:
  apply.arena2(Solver.prog(plan), rhs)

def apply.fin(+l: U32, ar: F.Ar) -> List<&2, G.Vec>:
  F.Flat.ar_list(l, ar)

# Replays a plan on the rhs symbols: `rhs` = one symbol per row of the system the plan was made from (same order,
# exactly Solver.plan_rows(plan) of them, all of the same length).  Returns C[0..l-1].  Pure; a plan may be applied
# any number of times (to different symbol sizes too).
def Solver.apply(plan: Plan, rhs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match plan:
    case Plan{+l, nrows, npiv, ntr, pivs, trs, tail}:
      apply.fin(l, Solver.apply_arena(Plan{l, nrows, npiv, ntr, pivs, trs, tail}, rhs))

# ===========================================================================
# 10. Public solve entry points = plan + apply
# ===========================================================================
def vwords(v: G.Vec) -> U32:
  match v:
    case G.VNode{l, r}:
      (vwords(l) + vwords(r) : U32)
    case G.VWord{w}:
      1
    case G.VNil{}:
      0

# the rhs symbols of the rows, in order
def rows_rhs(rows: List<&2, T.Row>, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match rows:
    case Nil{}:
      List.reverse(&2, G.Vec, acc)
    case r <> rest:
      match r:
        case T.Row{cols, rhs}:
          rows_rhs(rest, rhs <> acc)

def rhs_sw(rs: List<&2, G.Vec>) -> U32:
  match rs:
    case Nil{}:
      0
    case h <> t:
      vwords(h)

def solve_p.go(pl: Maybe<&2, Plan>, rhs: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match pl:
    case None{}:
      None{}
    case Some{plan}:
      Some{Solver.apply(plan, rhs)}

# Inactivation decoding = Solver.plan on the coefficients, then Solver.apply on the rhs symbols.
# p = number of permanently inactive columns (the last p columns).
def Solver.solve_p(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  solve_p.go(Solver.plan(l, p, rows), rows_rhs(rows, Nil{}))

def Solver.solve(l: U32, rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  Solver.solve_p(l, 0, rows)

# ---------------------------------------------------------------------------
# Symbol slicing (opt-in parallelism).  The symbols of a system are independent of each other: slicing
# every rhs into 2^d word ranges (the subtrees at depth d of the balanced Vec; no copying) and applying the plan to
# the 2^d slices concurrently gives the same C after joining the slices (VNode{..} of the slice results is
# exactly the shape Vec.from_list builds).  The plan is computed once and shared, so only the symbol work is
# divided; this pays when symbols are long and threads are available; see docs/perf.md.  d = 0 is Solver.apply.
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

def slice_syms(rs: List<&2, G.Vec>, +d: Nat, +idx: U32) -> List<&2, G.Vec>:
  match rs:
    case Nil{}:
      Nil{}
    case h <> t:
      vsub(d, idx, h) <> slice_syms(t, d, idx)

def vjoin(a: List<&2, G.Vec>, b: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match a b:
    case x <> xs y <> ys:
      G.VNode{x, y} <> vjoin(xs, ys)
    case _ _:
      Nil{}

# A leaf of the sliced apply: its word slice of every rhs symbol, the program run on its own arena, the solution slices read out
def pa.leaf(+m: Pm, p: Array<U32>, rs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match m:
    case Pm{+l, nrows, npiv, ntr, nin}:
      F.Flat.ar_list(l, Solver.apply_prog(m, p, rs))

# k = fork levels left, d = total slicing depth, idx = slice prefix; r = two copies of the program.  ONE region: the
# whole tree is a single parallel region, leaves allocate their own arena, the program is read-only shared (docs/scaling.md)
def pa.tree(+k: Nat, +d: Nat, +idx: U32, +m: Pm, r: Array<U32> & Array<U32>, +rhs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match k:
    case 0n:
      (p, p2) = r
      pa.leaf(m, p, slice_syms(rhs, d, idx))
    case 1n+q:
      (p1, p2) = r
      a b = pa.tree(q, d, (idx * 2 : U32), m, Array.clone(U32, p1), rhs) pa.tree(q, d, (idx * 2 + 1 : U32), m, Array.clone(U32, p2), rhs)
      vjoin(a, b)

def pa.run(+dd: Nat, pg: Pg, +rhs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match pg:
    case Pg{p, m}:
      pa.tree(dd, dd, 0, m, Array.clone(U32, p), rhs)

def sw_log(+sw: U32) -> Nat:
  match sw:
    case 0:
      0n
    case _:
      U32.log2(sw)

def apply_par2(+dd: Nat, +plan: Plan, +rhs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match dd:
    case 0n:
      Solver.apply(plan, rhs)
    case 1n+q:
      pa.run(dd, Solver.prog(plan), rhs)

# Same answer as Solver.apply, with the symbols sliced into 2^min(d, log2(words per symbol)) parts that are
# processed in parallel (see above).  Pass the thread count's log2 (e.g. 3 or 4 for 8..16 slices) or 0.
def Solver.apply_par(+d: U32, +plan: Plan, +rhs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  apply_par2(cap(U32.to_nat(d), sw_log(rhs_sw(rhs))), plan, rhs)

def solve_par.go(pl: Maybe<&2, Plan>, +d: U32, rhs: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match pl:
    case None{}:
      None{}
    case Some{plan}:
      Some{Solver.apply_par(d, plan, rhs)}

# Same answer as Solver.solve_p; the plan is computed once and applied to 2^d symbol slices in parallel.
def Solver.solve_par(+l: U32, +p: U32, +d: U32, +rows: List<&2, T.Row>) -> Maybe<&2, List<&2, G.Vec>>:
  solve_par.go(Solver.plan(l, p, rows), d, rows_rhs(rows, Nil{}))

# Slicing depth for t threads, symbols of sw words and nrows rhs symbols: none below 64 words (256 octets) or below
# AUTO_MIN_WORDS() words of symbol data in total, else log2(threads) capped at 3 (8 slices; 16 slices on 12 threads were
# slower, see docs/perf.md).  Since the symbol work runs on a flat arena (docs/plan_apply.md, update) one apply costs only about
# 4 ns per word, so a slice pays back its fork rounds, per-slice table and read-out only for very large blocks:
# measured on 12 threads, K = 1000..4000 T = 1024 (0.3-1M words) slicing is 1.0-1.5x SLOWER, K = 10000 T = 1024 (2.7M words) +-0.
def AUTO_MIN_WORDS() -> U32:
  8388608

def auto_d.go(small: Bool, +t: U32) -> U32:
  match small:
    case True{}:
      0
    case False{}:
      U32.min(3, U32.from_nat(U32.log2(U32.max(t, 1))))

def Solver.auto_depth(+t: U32, +sw: U32, +nrows: U32) -> U32:
  auto_d.go(Bool.or(U32.is_lt(sw, 64), U32.is_lt((nrows * sw : U32), AUTO_MIN_WORDS())), t)

def apply_auto2(t: U32, +plan: Plan, +rhs: List<&2, G.Vec>) -> List<&2, G.Vec>:
  Solver.apply_par(Solver.auto_depth(t, rhs_sw(rhs), Solver.plan_rows(plan)), plan, rhs)

# Solver.apply_par with the slicing depth chosen from the thread count of the running binary (IO.thread_count)
# and the symbol size.  For callers that live in IO.
def Solver.apply_auto(+plan: Plan, +rhs: List<&2, G.Vec>) -> IO(List<&2, G.Vec>):
  do IO<List<&2, G.Vec>>:
    t : U32 <- IO.thread_count()
    IO.pure(List<&2, G.Vec>, apply_auto2(t, plan, rhs))

def solve_auto.go(pl: Maybe<&2, Plan>, t: U32, rhs: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match pl:
    case None{}:
      None{}
    case Some{plan}:
      Some{apply_auto2(t, plan, rhs)}

# Solver.solve_par with the slicing depth chosen from the thread count and the symbol size.
def Solver.solve_auto(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  do IO<Maybe<&2, List<&2, G.Vec>>>:
    t : U32 <- IO.thread_count()
    IO.pure(Maybe<&2, List<&2, G.Vec>>, solve_auto.go(Solver.plan(l, p, rows), t, rows_rhs(rows, Nil{})))

# Diagnostics: size of the dense inactive system after phase 1 (columns that are not pivots).
def inactive_count.fin(st: P1, +l: U32) -> U32:
  match st:
    case P1{rows, wt, bk, ci, dn, pivs, done}:
      match pivs:
        case Pl{n, pl, nin, il, p}:
          (l - n : U32)

def Solver.inactive_count(+l: U32, +p: U32, +rows: List<&2, T.Row>) -> U32:
  inactive_count.fin(phase1(l, p, U32.from_nat(List.length(&2, T.Row, rows)), rows, nwords(l)), l)
