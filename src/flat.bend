# Flat symbol storage: symbols as slices of ONE `Array<U32>` (4 octets per slot, big-endian packed like `G.Vec` words), and
# tail-recursive slice kernels over it.  Added alongside the `G.Vec` tree (which keeps its API and its proofs); see
# docs/profile.md for why (a tree symbol costs two heap nodes per word and a non-tail walk per operation, a flat array
# 1-2 ns per slot access in a tail loop).
#
#   Flat.of_vec(v)                   Vec -> new Array<U32> (words 0.., power-of-two slots, zero padded)
#   Flat.to_vec(n, a)                first n words of the array -> balanced Vec (the shape of `Vec.from_list`)
#   Flat.put_vec(v, base, a)         write the words of v at slots base.. (returns the array)
#   Flat.get_vec(a, base, n)         n words at base -> Vec, and the array back (type Bv)
#   Flat.encode_tree / Flat.encode_list   encoding symbols for ESI esi0.. from the L intermediate symbols (RFC 5.3.5.3):
#                                    the intermediate symbols are copied ONCE into one flat array, each encoding symbol is
#                                    a tail loop XORing the needed slices into a scratch slice, then read out as a Vec.
#
# Idioms (docs/profile.md section 5): `Array.get` hands the array back next to the value, so every access is a helper def
# that destructures the pair; loops are Nat-fuel tail recursion; the array is threaded through the loop.
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./constraints.bend as C

# an array and a position / a decoded vector
type Fi is Type:
  Fi{i: U32, a: Array<U32>}

type Bv is Type:
  Bv{v: G.Vec, a: Array<U32>}

def Flat.fi_arr(f: Fi) -> Array<U32>:
  match f:
    case Fi{i, a}:
      a

# ---------------------------------------------------------------------------
# Vec -> flat
# ---------------------------------------------------------------------------

# Write the c words of v at base.. (left to right).  The tree is walked with its word count: a node of c words has a left
# subtree of c >> 1 words (the shape `Vec.from_list` / `Vec.build` makes, which every symbol of the codec has), so the
# slot of every leaf is known without threading a position through the recursion and the loop only touches the array.
def Flat.put.go(v: G.Vec, +c: U32, +i: U32, a: Array<U32>) -> Array<U32>:
  match v:
    case G.VNil{}:
      a
    case G.VWord{w}:
      Array.set(U32, a, i, w)
    case G.VNode{l, r}:
      +h = U32.shr(c)
      Flat.put.go(r, (c - h : U32), (i + h : U32), Flat.put.go(l, h, i, a))

def Flat.words(v: G.Vec) -> U32:
  match v:
    case G.VNil{}:
      0
    case G.VWord{_}:
      1
    case G.VNode{l, r}:
      (Flat.words(l) + Flat.words(r) : U32)

# the words of v written at base.. (v must have the standard balanced shape), array back
def Flat.put_vec(+v: G.Vec, +base: U32, a: Array<U32>) -> Array<U32>:
  Flat.put.go(v, Flat.words(v), base, a)

# a new array holding the words of v at 0.. (2^d slots, 2^d >= words, zero padding)
def Flat.of_vec(+v: G.Vec) -> Array<U32>:
  Flat.put_vec(v, 0, Array.new(U32, G.Vec.clog(Flat.words(v)), 0))

# ---------------------------------------------------------------------------
# flat -> Vec: the balanced tree of `Vec.build` (left half = c >> 1 words, right half the rest).
# `go` threads the array through the recursion; the left sibling's result is handed to the right call in `st` (its `v`
# field) and consumed by `fin` (a match cannot scrutinise a call result and mutual recursion is not allowed, so the
# combination step is a non-recursive def that receives the right call's result as an argument).
# ---------------------------------------------------------------------------

def Flat.tv.fin(sv: G.Vec, r: Bv, +right: Bool) -> Bv:
  match r:
    case Bv{rv, a}:
      match right:
        case True{}:
          Bv{G.VNode{sv, rv}, a}
        case False{}:
          Bv{rv, a}

def Flat.tv.leaf(r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Bv{G.VWord{x}, a}

# 4 words at base.. in one step (a node of 4 words is VNode{VNode{w0, w1}, VNode{w2, w3}}), 2 words likewise: the combination
# step then runs once per 4 words instead of once per word
def Flat.tv.q3(+x0: U32, +x1: U32, +x2: U32, r: Array<U32> & U32) -> Bv:
  (a, x3) = r
  Bv{G.VNode{G.VNode{G.VWord{x0}, G.VWord{x1}}, G.VNode{G.VWord{x2}, G.VWord{x3}}}, a}

def Flat.tv.q2(+x0: U32, +x1: U32, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x2) = r
  Flat.tv.q3(x0, x1, x2, Array.get(U32, a, (base + 3 : U32)))

def Flat.tv.q1(+x0: U32, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x1) = r
  Flat.tv.q2(x0, x1, base, Array.get(U32, a, (base + 2 : U32)))

def Flat.tv.q0(+base: U32, r: Array<U32> & U32) -> Bv:
  (a, x0) = r
  Flat.tv.q1(x0, base, Array.get(U32, a, (base + 1 : U32)))

def Flat.tv.d1(+x0: U32, r: Array<U32> & U32) -> Bv:
  (a, x1) = r
  Bv{G.VNode{G.VWord{x0}, G.VWord{x1}}, a}

def Flat.tv.d0(+base: U32, r: Array<U32> & U32) -> Bv:
  (a, x0) = r
  Flat.tv.d1(x0, Array.get(U32, a, (base + 1 : U32)))

# 16 words at base.. in one step: b_i reads word i and keeps the subtrees finished so far (binary-counter style merge, unrolled; shape
# of a 16-word `Vec.build` node).  Generated by tools/gen_flat_blocks.py.
# BEGIN generated (tools/gen_flat_blocks.py)
def Flat.tv.b15(+s0: G.Vec, +s1: G.Vec, +s2: G.Vec, +s3: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Bv{G.VNode{s0, G.VNode{s1, G.VNode{s2, G.VNode{s3, G.VWord{x}}}}}, a}

def Flat.tv.b14(+s0: G.Vec, +s1: G.Vec, +s2: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b15(s0, s1, s2, G.VWord{x}, base, Array.get(U32, a, (base + 15 : U32)))

def Flat.tv.b13(+s0: G.Vec, +s1: G.Vec, +s2: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b14(s0, s1, G.VNode{s2, G.VWord{x}}, base, Array.get(U32, a, (base + 14 : U32)))

def Flat.tv.b12(+s0: G.Vec, +s1: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b13(s0, s1, G.VWord{x}, base, Array.get(U32, a, (base + 13 : U32)))

def Flat.tv.b11(+s0: G.Vec, +s1: G.Vec, +s2: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b12(s0, G.VNode{s1, G.VNode{s2, G.VWord{x}}}, base, Array.get(U32, a, (base + 12 : U32)))

def Flat.tv.b10(+s0: G.Vec, +s1: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b11(s0, s1, G.VWord{x}, base, Array.get(U32, a, (base + 11 : U32)))

def Flat.tv.b9(+s0: G.Vec, +s1: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b10(s0, G.VNode{s1, G.VWord{x}}, base, Array.get(U32, a, (base + 10 : U32)))

def Flat.tv.b8(+s0: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b9(s0, G.VWord{x}, base, Array.get(U32, a, (base + 9 : U32)))

def Flat.tv.b7(+s0: G.Vec, +s1: G.Vec, +s2: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b8(G.VNode{s0, G.VNode{s1, G.VNode{s2, G.VWord{x}}}}, base, Array.get(U32, a, (base + 8 : U32)))

def Flat.tv.b6(+s0: G.Vec, +s1: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b7(s0, s1, G.VWord{x}, base, Array.get(U32, a, (base + 7 : U32)))

def Flat.tv.b5(+s0: G.Vec, +s1: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b6(s0, G.VNode{s1, G.VWord{x}}, base, Array.get(U32, a, (base + 6 : U32)))

def Flat.tv.b4(+s0: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b5(s0, G.VWord{x}, base, Array.get(U32, a, (base + 5 : U32)))

def Flat.tv.b3(+s0: G.Vec, +s1: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b4(G.VNode{s0, G.VNode{s1, G.VWord{x}}}, base, Array.get(U32, a, (base + 4 : U32)))

def Flat.tv.b2(+s0: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b3(s0, G.VWord{x}, base, Array.get(U32, a, (base + 3 : U32)))

def Flat.tv.b1(+s0: G.Vec, +base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b2(G.VNode{s0, G.VWord{x}}, base, Array.get(U32, a, (base + 2 : U32)))

def Flat.tv.b0(+base: U32, r: Array<U32> & U32) -> Bv:
  (a, x) = r
  Flat.tv.b1(G.VWord{x}, base, Array.get(U32, a, (base + 1 : U32)))

# END generated

def Flat.tv.go(+d: Nat, st: Bv, +c: U32, +base: U32, +right: Bool) -> Bv:
  match d:
    case 0n:
      st
    case 1n+p:
      match st:
        case Bv{sv, a}:
          match c:
            case 0:
              Flat.tv.fin(sv, Bv{G.VNil{}, a}, right)
            case 1:
              Flat.tv.fin(sv, Flat.tv.leaf(Array.get(U32, a, base)), right)
            case 2:
              Flat.tv.fin(sv, Flat.tv.d0(base, Array.get(U32, a, base)), right)
            case 4:
              Flat.tv.fin(sv, Flat.tv.q0(base, Array.get(U32, a, base)), right)
            case 16:
              Flat.tv.fin(sv, Flat.tv.b0(base, Array.get(U32, a, base)), right)
            case _:
              +h = U32.shr(c)
              Flat.tv.fin(sv, Flat.tv.go(p, Flat.tv.go(p, Bv{G.VNil{}, a}, h, base, False{}), (c - h : U32), (base + h : U32), True{}), right)

# c words at base, and the array back
def Flat.get_vec(a: Array<U32>, +base: U32, +c: U32) -> Bv:
  Flat.tv.go(32n, Bv{G.VNil{}, a}, c, base, False{})

def Flat.bv_vec(b: Bv) -> G.Vec:
  match b:
    case Bv{v, a}:
      v

# n words at base (array dropped)
def Flat.get_vec_only(a: Array<U32>, +base: U32, +n: U32) -> G.Vec:
  Flat.bv_vec(Flat.get_vec(a, base, n))

def Flat.to_vec(+n: U32, a: Array<U32>) -> G.Vec:
  Flat.bv_vec(Flat.get_vec(a, 0, n))

# ---------------------------------------------------------------------------
# Slice kernels on one array: a[db + j] (op)= a[sb + j] for j in 0..n-1.  `c` is a GF(256) octet, products by the SWAR `G.mulw`.
# ---------------------------------------------------------------------------

def Flat.xr.f2(+j: U32, +db: U32, +x: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, y) = rd
  Array.set(U32, a, (db + j : U32), U32.xor(y, x))

def Flat.xr.f1(+j: U32, +db: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, x) = rs
  Flat.xr.f2(j, db, x, Array.get(U32, a, (db + j : U32)))

def Flat.xr.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.xr.loop(q, U32.inc(j), db, sb, Flat.xr.f1(j, db, Array.get(U32, a, (sb + j : U32))))

# d = s
def Flat.cp.f1(+j: U32, +db: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, x) = rs
  Array.set(U32, a, (db + j : U32), x)

def Flat.cp.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.cp.loop(q, U32.inc(j), db, sb, Flat.cp.f1(j, db, Array.get(U32, a, (sb + j : U32))))

# d = 0
def Flat.zr.loop(+n: Nat, +j: U32, +db: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.zr.loop(q, U32.inc(j), db, Array.set(U32, a, (db + j : U32), 0))

# d = c * s
def Flat.ms.f1(+j: U32, +db: U32, +c: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, x) = rs
  Array.set(U32, a, (db + j : U32), G.mulw(c, x))

def Flat.ms.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, +c: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.ms.loop(q, U32.inc(j), db, sb, c, Flat.ms.f1(j, db, c, Array.get(U32, a, (sb + j : U32))))

# d ^= c * s
def Flat.ma.f2(+j: U32, +db: U32, +c: U32, +x: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, y) = rd
  Array.set(U32, a, (db + j : U32), U32.xor(y, G.mulw(c, x)))

def Flat.ma.f1(+j: U32, +db: U32, +c: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, x) = rs
  Flat.ma.f2(j, db, c, x, Array.get(U32, a, (db + j : U32)))

def Flat.ma.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, +c: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.ma.loop(q, U32.inc(j), db, sb, c, Flat.ma.f1(j, db, c, Array.get(U32, a, (sb + j : U32))))

# ---------------------------------------------------------------------------
# Table kernels.  The 64K-entry product table T[(c << 8) | b] = c * b (one octet per slot, built once per arena) lives at slots
# 0..65535 of the SAME array as the symbols (one array to thread through every loop); a word product is four table lookups.
# Measured (tools/profile/mb_arr.bend, 64K table in its own array): 2.9 ns per word, bit-sliced SWAR 4.2, G.mulw loop 8.6.
# ---------------------------------------------------------------------------

# T[i] = G.mul(i >> 8, i & 255) for i in 0..n-1 (n = 65536)
def Flat.tab.go(+n: Nat, +i: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.tab.go(q, U32.inc(i), Array.set(U32, a, i, G.mul(U32.shrn(i, 8n), U32.and(i, 255))))

def Flat.table(a: Array<U32>) -> Array<U32>:
  Flat.tab.go(65536n, 0, a)

# d = c * s  (c8 = c << 8)
def Flat.ts.g4(+j: U32, +db: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p0) = r
  Array.set(U32, a, (db + j : U32), (acc .|. p0 : U32))

def Flat.ts.g3(+j: U32, +db: U32, +c8: U32, +x: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p1) = r
  Flat.ts.g4(j, db, (acc .|. U32.shln(p1, 8n) : U32), Array.get(U32, a, (c8 + U32.and(x, 255) : U32)))

def Flat.ts.g2(+j: U32, +db: U32, +c8: U32, +x: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p2) = r
  Flat.ts.g3(j, db, c8, x, (acc .|. U32.shln(p2, 16n) : U32), Array.get(U32, a, (c8 + U32.and(U32.shrn(x, 8n), 255) : U32)))

def Flat.ts.g1(+j: U32, +db: U32, +c8: U32, +x: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p3) = r
  Flat.ts.g2(j, db, c8, x, U32.shln(p3, 24n), Array.get(U32, a, (c8 + U32.and(U32.shrn(x, 16n), 255) : U32)))

def Flat.ts.f1(+j: U32, +db: U32, +c8: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, +x) = rs
  Flat.ts.g1(j, db, c8, x, Array.get(U32, a, (c8 + U32.shrn(x, 24n) : U32)))

def Flat.ts.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, +c8: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.ts.loop(q, U32.inc(j), db, sb, c8, Flat.ts.f1(j, db, c8, Array.get(U32, a, (sb + j : U32))))

# d ^= c * s
def Flat.tm.g4(+j: U32, +db: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p0) = r
  Array.set(U32, a, (db + j : U32), U32.xor(y, (acc .|. p0 : U32)))

def Flat.tm.g3(+j: U32, +db: U32, +c8: U32, +x: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p1) = r
  Flat.tm.g4(j, db, y, (acc .|. U32.shln(p1, 8n) : U32), Array.get(U32, a, (c8 + U32.and(x, 255) : U32)))

def Flat.tm.g2(+j: U32, +db: U32, +c8: U32, +x: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p2) = r
  Flat.tm.g3(j, db, c8, x, y, (acc .|. U32.shln(p2, 16n) : U32), Array.get(U32, a, (c8 + U32.and(U32.shrn(x, 8n), 255) : U32)))

def Flat.tm.g1(+j: U32, +db: U32, +c8: U32, +x: U32, +y: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, p3) = r
  Flat.tm.g2(j, db, c8, x, y, U32.shln(p3, 24n), Array.get(U32, a, (c8 + U32.and(U32.shrn(x, 16n), 255) : U32)))

def Flat.tm.f2(+j: U32, +db: U32, +c8: U32, +x: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, +y) = rd
  Flat.tm.g1(j, db, c8, x, y, Array.get(U32, a, (c8 + U32.shrn(x, 24n) : U32)))

def Flat.tm.f1(+j: U32, +db: U32, +c8: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, +x) = rs
  Flat.tm.f2(j, db, c8, x, Array.get(U32, a, (db + j : U32)))

def Flat.tm.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, +c8: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      Flat.tm.loop(q, U32.inc(j), db, sb, c8, Flat.tm.f1(j, db, c8, Array.get(U32, a, (sb + j : U32))))

# ---------------------------------------------------------------------------
# Row operations on symbol slices (words at slot offsets db, sb), with or without the table (tab = False: SWAR `G.mulw`, no
# table to build, better for symbols of a few words).  axpy: d ^= c*s; axset: d = c*s; scale: d = c*d.
# ---------------------------------------------------------------------------
def Flat.axpy(+c: U32, +tab: Bool, +w: Nat, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  match c:
    case 0:
      a
    case 1:
      Flat.xr.loop(w, 0, db, sb, a)
    case _:
      match tab:
        case True{}:
          Flat.tm.loop(w, 0, db, sb, U32.shln(c, 8n), a)
        case False{}:
          Flat.ma.loop(w, 0, db, sb, c, a)

def Flat.axset(+c: U32, +tab: Bool, +w: Nat, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  match c:
    case 0:
      Flat.zr.loop(w, 0, db, a)
    case 1:
      Flat.cp.loop(w, 0, db, sb, a)
    case _:
      match tab:
        case True{}:
          Flat.ts.loop(w, 0, db, sb, U32.shln(c, 8n), a)
        case False{}:
          Flat.ms.loop(w, 0, db, sb, c, a)

# d = c * d
def Flat.scale(+c: U32, +tab: Bool, +w: Nat, +db: U32, a: Array<U32>) -> Array<U32>:
  match c:
    case 1:
      a
    case _:
      Flat.axset(c, tab, w, db, db, a)

# d ^= sum over terms Term{idx, f} of f * (symbol idx at slot base + idx * wu); `first` = the destination is not initialised yet:
# the first term sets it (an empty list zeroes it)
def Flat.fold.go(ts: List<&2, Y.Term>, +tab: Bool, +w: Nat, +wu: U32, +db: U32, +base: U32, a: Array<U32>) -> Array<U32>:
  match ts:
    case Nil{}:
      a
    case Con{t, rest}:
      match t:
        case Y.Term{i, f}:
          Flat.fold.go(rest, tab, w, wu, db, base, Flat.axpy(f, tab, w, db, (base + i * wu : U32), a))

def Flat.fold(ts: List<&2, Y.Term>, +tab: Bool, +w: Nat, +wu: U32, +db: U32, +base: U32, a: Array<U32>) -> Array<U32>:
  match ts:
    case Nil{}:
      Flat.zr.loop(w, 0, db, a)
    case Con{t, rest}:
      match t:
        case Y.Term{i, f}:
          Flat.fold.go(rest, tab, w, wu, db, base, Flat.axset(f, tab, w, db, (base + i * wu : U32), a))

# ---------------------------------------------------------------------------
# Encoding symbols (RFC 5.3.5.3): the intermediate symbols C[0..L-1] sit at slots c*W.. of one array (W words per symbol);
# the slice at `ob` = L*W is scratch.  An encoding symbol is the sum of C[col] over the LT/PI columns: the first term
# initialises the scratch slice, the rest are XORed in, then the slice is read out as a Vec.
# ---------------------------------------------------------------------------

type Gs is Type:
  Gs{a: Array<U32>, acc: List<&2, G.Vec>}

def Flat.mkbv(a: Array<U32>) -> Bv:
  Bv{G.VNil{}, a}

def Flat.gen.fin(acc: List<&2, G.Vec>, r: Bv) -> Gs:
  match r:
    case Bv{v, a}:
      Gs{a, v <> acc}

def Flat.gen.one(+esi: U32, +k: U32, +sp: T.SP, +w: Nat, +wu: U32, +cb: U32, +ob: U32, st: Gs) -> Gs:
  match st:
    case Gs{a, acc}:
      Flat.gen.fin(acc, Flat.tv.go(32n, Flat.mkbv(Flat.fold(C.lt_terms(sp, C.isi_of(esi, k, R.Kp(sp))), False{}, w, wu, ob, cb, a)), wu, ob, False{}))

# encoding symbols esi, esi-1, ..., esi-n+1 prepended to the accumulator (so the result is ascending)
def Flat.gen(+n: Nat, +esi: U32, +k: U32, +sp: T.SP, +w: Nat, +wu: U32, +cb: U32, +ob: U32, st: Gs) -> Gs:
  match n:
    case 0n:
      st
    case 1n+q:
      Flat.gen(q, (esi - 1 : U32), k, sp, w, wu, cb, ob, Flat.gen.one(esi, k, sp, w, wu, cb, ob, st))

def Flat.gs_list(st: Gs) -> List<&2, G.Vec>:
  match st:
    case Gs{a, acc}:
      acc

# l symbols of wu words at slots ca.. -> list of Vecs (ascending), array dropped
def Flat.sym_list.go(+n: Nat, +c: U32, +ca: U32, +wu: U32, st: Gs) -> Gs:
  match n:
    case 0n:
      st
    case 1n+q:
      match st:
        case Gs{a, acc}:
          Flat.sym_list.go(q, (c - 1 : U32), ca, wu, Flat.gen.fin(acc, Flat.get_vec(a, (ca + c * wu : U32), wu)))

def Flat.sym_list(+l: U32, +ca: U32, +wu: U32, a: Array<U32>) -> List<&2, G.Vec>:
  Flat.gs_list(Flat.sym_list.go(U32.to_nat(l), (l - 1 : U32), ca, wu, Gs{a, []}))

# A solved arena (Solver.apply_arena): the l intermediate symbols at slots ca.., a scratch symbol at sc
type Ar is Type:
  Ar{a: Array<U32>, wu: U32, ca: U32, sc: U32}

def Flat.ar_list(+l: U32, ar: Ar) -> List<&2, G.Vec>:
  match ar:
    case Ar{a, wu, ca, sc}:
      Flat.sym_list(l, ca, wu, a)

def Flat.encode_ar.go(+n: U32, +esi0: U32, +k: U32, +sp: T.SP, ar: Ar) -> List<&2, G.Vec>:
  match ar:
    case Ar{a, +wu, ca, sc}:
      Flat.gs_list(Flat.gen(U32.to_nat(n), (esi0 + n - 1 : U32), k, sp, U32.to_nat(wu), wu, ca, sc, Gs{a, []}))

# n encoding symbols esi0.. from the intermediate symbols of a solved arena (consumes it)
def Flat.encode_arena(+sp: T.SP, +k: U32, ar: Ar, +esi0: U32, +n: U32) -> List<&2, G.Vec>:
  Flat.encode_ar.go(n, esi0, k, sp, ar)

# the fresh array for L symbols of wu words (+ scratch slice), holding the position 0
def Flat.arena(+l: U32, +wu: U32) -> Fi:
  Fi{0, Array.new(U32, G.Vec.clog(((l + 1) * wu : U32)), 0)}

def Flat.run(+n: U32, +esi0: U32, +k: U32, +sp: T.SP, +wu: U32, f: Fi) -> List<&2, G.Vec>:
  Flat.gs_list(Flat.gen(U32.to_nat(n), (esi0 + n - 1 : U32), k, sp, U32.to_nat(wu), wu, 0, (R.L(sp) * wu : U32), Gs{Flat.fi_arr(f), []}))

# one symbol of wu words at slot f.i; the next free slot comes back
def Flat.fill1(+v: G.Vec, +wu: U32, f: Fi) -> Fi:
  match f:
    case Fi{+i, a}:
      Fi{(i + wu : U32), Flat.put.go(v, wu, i, a)}

# ---- from the codec's ITree (Enc) -------------------------------------------------------------------------------------
def Flat.itree_first(tr: C.ITree) -> G.Vec:
  match tr:
    case C.INil{}:
      G.VNil{}
    case C.ILeaf{v}:
      v
    case C.INode{_, l, r}:
      Flat.itree_first(l)

# the symbols of the tree (wu words each) at slots 0.. in order; Fi = (next slot, array)
def Flat.tfill(tr: C.ITree, +wu: U32, f: Fi) -> Fi:
  match tr:
    case C.INil{}:
      f
    case C.ILeaf{v}:
      Flat.fill1(v, wu, f)
    case C.INode{_, l, r}:
      Flat.tfill(r, wu, Flat.tfill(l, wu, f))

def Flat.enc_tree.go(+sp: T.SP, +k: U32, +tr: C.ITree, +esi0: U32, +n: U32, +wu: U32) -> List<&2, G.Vec>:
  Flat.run(n, esi0, k, sp, wu, Flat.tfill(tr, wu, Flat.arena(R.L(sp), wu)))

# words per symbol (taken from the first intermediate symbol)
def Flat.words_of_tree(+tr: C.ITree) -> U32:
  Flat.words(Flat.itree_first(tr))

# The n encoding symbols esi0.. (external ESIs) for K source symbols, from the indexed intermediate symbols.  Same symbols as
# `C.encode_idx` per ESI (empty symbols give VNil symbols).
def Flat.encode_tree(+sp: T.SP, +k: U32, +tr: C.ITree, +esi0: U32, +n: U32) -> List<&2, G.Vec>:
  Flat.enc_tree.go(sp, k, tr, esi0, n, Flat.words_of_tree(tr))

# ---- from a list of the L intermediate symbols (decoder) --------------------------------------------------------------
def Flat.lfill(xs: List<&2, G.Vec>, +wu: U32, f: Fi) -> Fi:
  match xs:
    case Nil{}:
      f
    case Con{v, rest}:
      Flat.lfill(rest, wu, Flat.fill1(v, wu, f))

def Flat.first_of_list(xs: List<&2, G.Vec>) -> G.Vec:
  match xs:
    case Nil{}:
      G.VNil{}
    case Con{v, _}:
      v

def Flat.enc_list.go(+sp: T.SP, +k: U32, inter: List<&2, G.Vec>, +esi0: U32, +n: U32, +wu: U32) -> List<&2, G.Vec>:
  Flat.run(n, esi0, k, sp, wu, Flat.lfill(inter, wu, Flat.arena(R.L(sp), wu)))

def Flat.encode_list(+sp: T.SP, +k: U32, inter: List<&2, G.Vec>, +esi0: U32, +n: U32) -> List<&2, G.Vec>:
  +ys = inter
  Flat.enc_list.go(sp, k, ys, esi0, n, Flat.words(Flat.first_of_list(ys)))
