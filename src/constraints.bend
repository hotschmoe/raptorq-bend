# Constraint matrix rows and the LT/PI encoder (RFC 6330 5.3.3.3, 5.3.5.3, 5.3.5.4).
# See docs/constraints.md.  Public API (import as `C`):
#   fixed(sp, t)            S LDPC rows then H HDPC rows (rhs = zero symbol of t octets)
#   lt_terms(sp, isi)       columns of Enc[K',(C),Tuple[K',isi]], all coef 1
#   source_rows(sp, src)    K' LT rows for ISI 0..K'-1, rhs = source symbol (zero past K)
#   received_rows(sp, k, recv)  decoder rows (ESI -> ISI) + padding rows for ISI k..K'-1
#   encode(sp, inter, isi)  evaluate the LT/PI combination over the intermediate symbols
#   index / encode_idx      encode against a prebuilt O(log L) lookup tree
import Base
import ./gf256.bend as G
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./types.bend as Y

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# zero symbol for symbol size t octets (ceil(t/4) packed words)
def zero(+t: U32) -> G.Vec:
  G.Vec.from_list(List.replicate(U32, U32.to_nat(((t + 3 : U32) >> 2n : U32)), 0))

def sub_if.go(+x: U32, +m: U32, big: Bool) -> U32:
  match big:
    case True{}:
      (x - m : U32)
    case False{}:
      x

# x - m if x >= m else x
def sub_if(+x: U32, +m: U32) -> U32:
  sub_if.go(x, m, U32.is_ge(x, m))

# (x + y) mod m for x, y < m  (no division)
def addmod(+x: U32, +y: U32, +m: U32) -> U32:
  sub_if((x + y : U32), m)

def keep_if(b: Bool, t: Y.Term, acc: List<&2, Y.Term>) -> List<&2, Y.Term>:
  match b:
    case True{}:
      t <> acc
    case False{}:
      acc

# 1 if either flag set else 0
def hit(ea: Bool, eb: Bool) -> U32:
  match ea:
    case True{}:
      1
    case False{}:
      match eb:
        case True{}:
          1
        case False{}:
          0

# ---------------------------------------------------------------------------
# LDPC rows (5.3.3.3).  Row r of the S x (B+S+P) system contains
#   C[B+r]                                   (the identity part)
#   C[W + r%P], C[W + (r+1)%P]               (second loop, i = r)
#   C[i] for each i<B with b_i, b_i+a_i, b_i+2a_i == r (mod S)  (first loop)
# For i = q*S + k (a = q+1, b_i = k) that last set is k = r - t*a mod S, t=0,1,2,
# so the row is built block by block (q) without scanning all B columns.
# ---------------------------------------------------------------------------

def ldpc.blk(n: Nat, +q: U32, +r: U32, +s: U32, +b: U32, acc: List<&2, Y.Term>) -> List<&2, Y.Term>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +step = (s - ((q + 1 : U32) % s) : U32)
      +k1 = addmod(r, step, s)
      +k2 = addmod(k1, step, s)
      +base = (q * s : U32)
      +c0 = (base + r : U32)
      +c1 = (base + k1 : U32)
      +c2 = (base + k2 : U32)
      a2 = keep_if(U32.is_lt(c2, b), Y.Term{c2, 1}, acc)
      a1 = keep_if(U32.is_lt(c1, b), Y.Term{c1, 1}, a2)
      a0 = keep_if(U32.is_lt(c0, b), Y.Term{c0, 1}, a1)
      ldpc.blk(p, (q - 1 : U32), r, s, b, a0)

def ldpc.terms(+r: U32, +s: U32, +b: U32, +w: U32, +p: U32) -> List<&2, Y.Term>:
  +nq = ((b + s - 1 : U32) / s : U32)
  ldpc.blk(U32.to_nat(nq), (nq - 1 : U32), r, s, b,
    Y.Term{(b + r : U32), 1} <> (Y.Term{(w + (r % p) : U32), 1} <> (Y.Term{(w + ((r + 1 : U32) % p) : U32), 1} <> [])))

# rows r = n-1 .. 0 prepended onto acc (so the result ascends); the rows' contents are
# independent redexes, so the runtime evaluates them in parallel
def ldpc.rows(n: Nat, +r: U32, +s: U32, +b: U32, +w: U32, +p: U32, +z: G.Vec, acc: List<&2, Y.Row>) -> List<&2, Y.Row>:
  match n:
    case 0n:
      acc
    case 1n+m:
      ldpc.rows(m, (r - 1 : U32), s, b, w, p, z, Y.Row{ldpc.terms(r, s, b, w, p), z} <> acc)

# ---------------------------------------------------------------------------
# HDPC rows (5.3.3.3): row i of  [ MT*GAMMA | I_H ].
# (MT*GAMMA)[i,c] = sum_{j>=c} MT[i,j] * alpha^(j-c), so with e(c) that entry
#   e(K'+S-1) = MT[i,K'+S-1] = alpha^i,   e(c) = MT[i,c] + alpha*e(c+1).
# MT[i,j] (j < K'+S-1) is 1 iff i = r1(j) or i = r2(j), where
#   r1 = Rand[j+1,6,H],  r2 = (r1 + Rand[j+1,7,H-1] + 1) % H.
# The (r1,r2) pairs are computed once and shared by all H rows (descending j).
# ---------------------------------------------------------------------------

type Pr is Data:
  Pr{a: U32, b: U32}

def pairs.go(n: Nat, +c: U32, +h: U32, acc: List<&2, Pr>) -> List<&2, Pr>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +r1 = R.rand((c + 1 : U32), 6, h)
      r2 = sub_if((r1 + R.rand((c + 1 : U32), 7, (h - 1 : U32)) + 1 : U32), h)
      pairs.go(p, (c + 1 : U32), h, Pr{r1, r2} <> acc)

# pairs for columns last-1 .. 0 (head = column last-1); last = K'+S-1
def pairs(+last: U32, +h: U32) -> List<&2, Pr>:
  pairs.go(U32.to_nat(last), 0, h, [])

def hd.go(lst: List<&2, Pr>, +c: U32, +i: U32, +e: U32, acc: List<&2, Y.Term>) -> List<&2, Y.Term>:
  match lst:
    case Nil{}:
      acc
    case Con{pr, tl}:
      match pr:
        case Pr{a, b}:
          +en = (G.xtime(e) .^. hit(U32.is_eq(i, a), U32.is_eq(i, b)) : U32)
          hd.go(tl, (c - 1 : U32), i, en, keep_if(U32.is_ne(en, 0), Y.Term{c, en}, acc))

def hd.terms(prs: List<&2, Pr>, +i: U32, +last: U32) -> List<&2, Y.Term>:
  +e = G.alpha_pow(i)
  hd.go(prs, (last - 1 : U32), i, e, Y.Term{last, e} <> (Y.Term{(last + 1 + i : U32), 1} <> []))

def hd.rows(n: Nat, +i: U32, +last: U32, +prs: List<&2, Pr>, +z: G.Vec, acc: List<&2, Y.Row>) -> List<&2, Y.Row>:
  match n:
    case 0n:
      acc
    case 1n+m:
      hd.rows(m, (i - 1 : U32), last, prs, z, Y.Row{hd.terms(prs, i, last), z} <> acc)

# S LDPC rows then H HDPC rows; rhs = zero symbol of t octets.
def fixed(+sp: T.SP, +t: U32) -> List<&2, Y.Row>:
  +z = zero(t)
  +s = R.S(sp)
  +h = R.H(sp)
  +last = (R.Kp(sp) + s - 1 : U32)
  ldpc.rows(U32.to_nat(s), (s - 1 : U32), s, R.B(sp), R.W(sp), R.P(sp), z,
    hd.rows(U32.to_nat(h), (h - 1 : U32), last, pairs(last, h), z, []))

# ---------------------------------------------------------------------------
# LT / PI terms (5.3.5.3): the columns Enc[K',(C),Tuple[K',X]] adds up.
# Order of the returned list is unspecified (all coefs are 1, columns distinct).
# ---------------------------------------------------------------------------

def lt.go(n: Nat, +b: U32, +a: U32, +w: U32, acc: List<&2, Y.Term>) -> List<&2, Y.Term>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +nb = addmod(b, a, w)
      lt.go(p, nb, a, w, Y.Term{nb, 1} <> acc)

# while (b1 >= P) b1 = (b1 + a1) % P1   (nf: at most P1-P+1 steps are ever needed)
def pi.go(nf: Nat, +b1: U32, +a1: U32, +p: U32, +p1: U32, big: Bool) -> U32:
  match nf big:
    case 1n+g True{}:
      +nb = addmod(b1, a1, p1)
      pi.go(g, nb, a1, p, p1, U32.is_ge(nb, p))
    case _ _:
      b1

def pi.skip(+b1: U32, +a1: U32, +p: U32, +p1: U32) -> U32:
  pi.go(U32.to_nat((p1 - p + 1 : U32)), b1, a1, p, p1, U32.is_ge(b1, p))

# n more PI terms, b1 already skipped/valid and already emitted
def pi.more(n: Nat, +b1: U32, +a1: U32, +w: U32, +p: U32, +p1: U32, acc: List<&2, Y.Term>) -> List<&2, Y.Term>:
  match n:
    case 0n:
      acc
    case 1n+m:
      +nb = pi.skip(addmod(b1, a1, p1), a1, p, p1)
      pi.more(m, nb, a1, w, p, p1, Y.Term{(w + nb : U32), 1} <> acc)

def lt_terms.go(t: R.Tup, +w: U32, +p: U32, +p1: U32) -> List<&2, Y.Term>:
  match t:
    case R.Tup{d, +a, +b, d1, +a1, +b1}:
      +c1 = pi.skip(b1, a1, p, p1)
      pi.more(U32.to_nat((d1 - 1 : U32)), c1, a1, w, p, p1,
        Y.Term{(w + c1 : U32), 1} <> lt.go(U32.to_nat((d - 1 : U32)), b, a, w, Y.Term{b, 1} <> []))

def lt_terms(+sp: T.SP, +isi: U32) -> List<&2, Y.Term>:
  lt_terms.go(R.tuple(sp, isi), R.W(sp), R.P(sp), R.P1(sp))

# ---------------------------------------------------------------------------
# Symbol lookup tree: O(log n) indexing of a list of symbols (lists are O(n)).
# ---------------------------------------------------------------------------

type ITree is Data:
  INil{}
  ILeaf{v: G.Vec}
  INode{nl: U32, l: ITree, r: ITree}

def ix.build(+d: Nat, +c: U32, +xs: List<&2, G.Vec>) -> ITree:
  match d:
    case 0n:
      INil{}
    case 1n+p:
      match c:
        case 0:
          INil{}
        case 1:
          match xs:
            case Nil{}:
              INil{}
            case Con{h, t}:
              ILeaf{h}
        case _:
          +h = U32.shr(c)
          l r = ix.build(p, h, List.take(&2, G.Vec, xs, U32.to_nat(h))) ix.build(p, (c - h : U32), List.drop(&2, G.Vec, xs, U32.to_nat(h)))
          INode{h, l, r}

def len.go(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len.go(t, (acc + 1 : U32))

def ix.pick(b: Bool, l: ITree, r: ITree) -> ITree:
  match b:
    case True{}:
      l
    case False{}:
      r

def ix.shift(b: Bool, +i: U32, +nl: U32) -> U32:
  match b:
    case True{}:
      i
    case False{}:
      (i - nl : U32)

def ix.leaf(ok: Bool, v: G.Vec, dflt: G.Vec) -> G.Vec:
  match ok:
    case True{}:
      v
    case False{}:
      dflt

# element i, or dflt when out of range.  d = depth fuel (the descent picks a child
# through a helper, which the termination checker cannot see as structural).
def ix.go(d: Nat, tr: ITree, +i: U32, dflt: G.Vec) -> G.Vec:
  match d:
    case 0n:
      dflt
    case 1n+e:
      match tr:
        case INil{}:
          dflt
        case ILeaf{v}:
          ix.leaf(U32.is_zero(i), v, dflt)
        case INode{+nl, l, r}:
          +lt = U32.is_lt(i, nl)
          ix.go(e, ix.pick(lt, l, r), ix.shift(lt, i, nl), dflt)

def ix.get(tr: ITree, +i: U32, dflt: G.Vec) -> G.Vec:
  ix.go(40n, tr, i, dflt)

def index(xs: List<&2, G.Vec>) -> ITree:
  +ys = xs
  ix.build(32n, len.go(ys, 0), ys)

# ---------------------------------------------------------------------------
# encode (5.3.5.3): sum of C[col] over lt_terms
# ---------------------------------------------------------------------------

def enc.go(+tr: ITree, ts: List<&2, Y.Term>, acc: G.Vec) -> G.Vec:
  match ts:
    case Nil{}:
      acc
    case Con{t, rest}:
      match t:
        case Y.Term{col, coef}:
          enc.go(tr, rest, G.Vec.muladd(coef, acc, ix.get(tr, col, G.VNil{})))

def enc.start(+tr: ITree, ts: List<&2, Y.Term>) -> G.Vec:
  match ts:
    case Nil{}:
      G.VNil{}
    case Con{t, rest}:
      match t:
        case Y.Term{col, coef}:
          enc.go(tr, rest, G.Vec.scale(coef, ix.get(tr, col, G.VNil{})))

def encode_idx(+sp: T.SP, +tr: ITree, +isi: U32) -> G.Vec:
  enc.start(tr, lt_terms(sp, isi))

def encode(+sp: T.SP, inter: List<&2, G.Vec>, +isi: U32) -> G.Vec:
  encode_idx(sp, index(inter), isi)

# ---------------------------------------------------------------------------
# Source / received rows
# ---------------------------------------------------------------------------

def zero_like(xs: List<&2, G.Vec>) -> G.Vec:
  match xs:
    case Nil{}:
      G.VNil{}
    case Con{h, t}:
      G.Vec.zeros(h)

# rows for ISI x = n-1 .. 0 (rhs = tree entry or dflt)
def src.go(n: Nat, +x: U32, +sp: T.SP, +tr: ITree, +z: G.Vec, acc: List<&2, Y.Row>) -> List<&2, Y.Row>:
  match n:
    case 0n:
      acc
    case 1n+m:
      src.go(m, (x - 1 : U32), sp, tr, z, Y.Row{lt_terms(sp, x), ix.get(tr, x, z)} <> acc)

# K' LT rows for ISI 0..K'-1, ascending; ISI >= K get a zero rhs (5.3.1 padding).
def source_rows(+sp: T.SP, source: List<&2, G.Vec>) -> List<&2, Y.Row>:
  +src = source
  +kp = R.Kp(sp)
  src.go(U32.to_nat(kp), (kp - 1 : U32), sp, index(src), zero_like(src), [])

def isi.go(b: Bool, +esi: U32, +d: U32) -> U32:
  match b:
    case True{}:
      esi
    case False{}:
      (esi + d : U32)

# external ESI -> ISI (5.3.1): ESI < K stays, repair ESI shifts by K'-K
def isi_of(+esi: U32, +k: U32, +kp: U32) -> U32:
  isi.go(U32.is_lt(esi, k), esi, (kp - k : U32))

def recv.go(lst: List<&2, Y.Rcv>, +sp: T.SP, +k: U32, +kp: U32, acc: List<&2, Y.Row>) -> List<&2, Y.Row>:
  match lst:
    case Nil{}:
      acc
    case Con{rc, tl}:
      match rc:
        case Y.Rcv{esi, sym}:
          recv.go(tl, sp, k, kp, Y.Row{lt_terms(sp, isi_of(esi, k, kp)), sym} <> acc)

def recv.zero(lst: List<&2, Y.Rcv>) -> G.Vec:
  match lst:
    case Nil{}:
      G.VNil{}
    case Con{rc, tl}:
      match rc:
        case Y.Rcv{esi, sym}:
          G.Vec.zeros(sym)

# padding rows ISI = x .. k (descending prepend), zero rhs
def pad.go(n: Nat, +x: U32, +sp: T.SP, +z: G.Vec, acc: List<&2, Y.Row>) -> List<&2, Y.Row>:
  match n:
    case 0n:
      acc
    case 1n+m:
      pad.go(m, (x - 1 : U32), sp, z, Y.Row{lt_terms(sp, x), z} <> acc)

# Decoder rows: one per received symbol (ISI from ESI), then K'-K padding rows
# (ISI K..K'-1, zero rhs).  Received rows come out in REVERSE of the input order,
# followed by the padding rows.
def received_rows(+sp: T.SP, +k: U32, recv: List<&2, Y.Rcv>) -> List<&2, Y.Row>:
  +rv = recv
  +kp = R.Kp(sp)
  recv.go(rv, sp, k, kp, pad.go(U32.to_nat((kp - k : U32)), (kp - 1 : U32), sp, recv.zero(rv), []))
