# Dense Gauss-Jordan over GF(256) with the matrix in ONE flat Array<U32> (row stride RS words, 4 octets per word) and the
# 64K-entry product table T[(c << 8) | b] in a second Array<U32>.  Same matrix / zero-pivot rule as mb_gj.c.
#   bend tools/profile/mb_gj.bend -o build/mb_gj_b ; ./build/mb_gj_b [--threads N] -- <n> <T octets>
import Base
import ../../src/gf256.bend as G

type St is Type:
  St{m: Array<U32>, t: Array<U32>}

# ---- row kernels ------------------------------------------------------------------------------------------
# d[ib+j] ^= c * s[sb+j]  for j in 0..n-1 (muladd), pivot row and target row both in m
def ma.w4(+ib: U32, +j: U32, +acc: U32, +y: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p0) = rt
  St{m[U32.add(ib, j)] <- U32.xor(y, (acc .|. p0 : U32)), t}

def ma.w3(+ib: U32, +j: U32, +c8: U32, +x: U32, +acc: U32, +y: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p1) = rt
  ma.w4(ib, j, (acc .|. U32.shln(p1, 8n) : U32), y, m, Array.get(U32, t, (c8 + U32.and(x, 255) : U32)))

def ma.w2(+ib: U32, +j: U32, +c8: U32, +x: U32, +acc: U32, +y: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p2) = rt
  ma.w3(ib, j, c8, x, (acc .|. U32.shln(p2, 16n) : U32), y, m, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 8n), 255) : U32)))

def ma.w1(+ib: U32, +j: U32, +c8: U32, +x: U32, +y: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p3) = rt
  ma.w2(ib, j, c8, x, U32.shln(p3, 24n), y, m, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 16n), 255) : U32)))

def ma.r2(+ib: U32, +j: U32, +c8: U32, +x: U32, t: Array<U32>, rm: Array<U32> & U32) -> St:
  (m, y) = rm
  ma.w1(ib, j, c8, x, y, m, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 24n), 255) : U32)))

def ma.r1(+ib: U32, +j: U32, +c8: U32, t: Array<U32>, rm: Array<U32> & U32) -> St:
  (m, x) = rm
  ma.r2(ib, j, c8, x, t, Array.get(U32, m, U32.add(ib, j)))

def ma.step(+ib: U32, +sb: U32, +j: U32, +c8: U32, st: St) -> St:
  St{m, t} = st
  ma.r1(ib, j, c8, t, Array.get(U32, m, U32.add(sb, j)))

def ma.loop(+n: Nat, +ib: U32, +sb: U32, +j: U32, +c8: U32, st: St) -> St:
  match n:
    case 0n:
      st
    case 1n+q:
      ma.loop(q, ib, sb, U32.inc(j), c8, ma.step(ib, sb, j, c8, st))

# scale in place: d[pb+j] = c * d[pb+j]
def sc.w4(+pb: U32, +j: U32, +acc: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p0) = rt
  St{m[U32.add(pb, j)] <- (acc .|. p0 : U32), t}

def sc.w3(+pb: U32, +j: U32, +c8: U32, +x: U32, +acc: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p1) = rt
  sc.w4(pb, j, (acc .|. U32.shln(p1, 8n) : U32), m, Array.get(U32, t, (c8 + U32.and(x, 255) : U32)))

def sc.w2(+pb: U32, +j: U32, +c8: U32, +x: U32, +acc: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p2) = rt
  sc.w3(pb, j, c8, x, (acc .|. U32.shln(p2, 16n) : U32), m, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 8n), 255) : U32)))

def sc.w1(+pb: U32, +j: U32, +c8: U32, +x: U32, m: Array<U32>, rt: Array<U32> & U32) -> St:
  (t, p3) = rt
  sc.w2(pb, j, c8, x, U32.shln(p3, 24n), m, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 16n), 255) : U32)))

def sc.r1(+pb: U32, +j: U32, +c8: U32, t: Array<U32>, rm: Array<U32> & U32) -> St:
  (m, +x) = rm
  sc.w1(pb, j, c8, x, m, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 24n), 255) : U32)))

def sc.step(+pb: U32, +j: U32, +c8: U32, st: St) -> St:
  St{m, t} = st
  sc.r1(pb, j, c8, t, Array.get(U32, m, U32.add(pb, j)))

def sc.loop(+n: Nat, +pb: U32, +j: U32, +c8: U32, st: St) -> St:
  match n:
    case 0n:
      st
    case 1n+q:
      sc.loop(q, pb, U32.inc(j), c8, sc.step(pb, j, c8, st))

# ---- octet c of row i: word (i*RS + c/4), byte c%4 ---------------------------------------------------
def oct(+w: U32, +c: U32) -> U32:
  U32.and(U32.shrn(w, U32.to_nat(U32.shln(U32.and(c, 3), 3n))), 255)

# ---- the elimination of column c from row i (i != c) --------------------------------------------------
def el.go(+f: U32, +rw: Nat, +ib: U32, +pb: U32, st: St) -> St:
  match f:
    case 0:
      st
    case _:
      ma.loop(rw, ib, pb, 0, U32.shln(f, 8n), st)

def el.f(+rw: Nat, +ib: U32, +pb: U32, +c: U32, +i: U32, +cw: U32, rm: Array<U32> & U32, t: Array<U32>) -> St:
  (m, w) = rm
  el.go(oct(w, c), rw, ib, pb, St{m, t})

def el.one(+rw: Nat, +rs: U32, +c: U32, +i: U32, st: St) -> St:
  St{m, t} = st
  el.f(rw, (i * rs : U32), (c * rs : U32), c, i, 0, Array.get(U32, m, (i * rs + U32.shrn(c, 2n) : U32)), t)

def el.skip(same: Bool, +rw: Nat, +rs: U32, +c: U32, +i: U32, st: St) -> St:
  match same:
    case True{}:
      st
    case False{}:
      el.one(rw, rs, c, i, st)

def el.rows(+n: Nat, +rw: Nat, +rs: U32, +c: U32, +i: U32, st: St) -> St:
  match n:
    case 0n:
      st
    case 1n+q:
      el.rows(q, rw, rs, c, U32.inc(i), el.skip(U32.is_eq(i, c), rw, rs, c, i, st))

# pivot processing for column c: scale the pivot row, then eliminate the column from all other rows
def col.go(+piv: U32, +n: Nat, +rw: Nat, +rs: U32, +c: U32, st: St) -> St:
  match piv:
    case 0:
      st
    case _:
      el.rows(n, rw, rs, c, 0, sc.loop(rw, (c * rs : U32), 0, U32.shln(G.inv(piv), 8n), st))

def col.f(+n: Nat, +rw: Nat, +rs: U32, +c: U32, rm: Array<U32> & U32, t: Array<U32>) -> St:
  (m, w) = rm
  col.go(oct(w, c), n, rw, rs, c, St{m, t})

def col.one(+n: Nat, +rw: Nat, +rs: U32, +c: U32, st: St) -> St:
  St{m, t} = st
  col.f(n, rw, rs, c, Array.get(U32, m, (c * rs + U32.shrn(c, 2n) : U32)), t)

def gj(+k: Nat, +n: Nat, +rw: Nat, +rs: U32, +c: U32, st: St) -> St:
  match k:
    case 0n:
      st
    case 1n+q:
      gj(q, n, rw, rs, U32.inc(c), col.one(n, rw, rs, c, st))

# ---- setup / checksum ------------------------------------------------------------------------------------------
def tb.go(+n: Nat, +i: U32, t: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      t
    case 1n+q:
      tb.go(q, U32.inc(i), t[i] <- G.mul(U32.shrn(i, 8n), U32.and(i, 255)))

type Fl is Type:
  Fl{m: Array<U32>, x: U32}

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def fr.put(+k: U32, fl: Fl) -> Fl:
  match fl:
    case Fl{m, +x}:
      Fl{m[k] <- lcg(x), lcg(x)}

# row i: words 0..rw-1 from the LCG stream
def fr.go(+n: Nat, +b: U32, +j: U32, fl: Fl) -> Fl:
  match n:
    case 0n:
      fl
    case 1n+q:
      fr.go(q, b, U32.inc(j), fr.put(U32.add(b, j), fl))

def fm.go(+n: Nat, +rw: Nat, +rs: U32, +i: U32, fl: Fl) -> Fl:
  match n:
    case 0n:
      fl
    case 1n+q:
      fm.go(q, rw, rs, U32.inc(i), fr.go(rw, (i * rs : U32), 0, fl))

type Fl2 is Type:
  Fl2{m: Array<U32>, acc: U32}

def cs.go(+n: Nat, +b: U32, +j: U32, +acc: U32, r: Array<U32> & U32) -> Fl2:
  match n r:
    case 0n Tuple{m, x}:
      Fl2{m, acc}
    case 1n+q Tuple{m, x}:
      cs.go(q, b, U32.inc(j), (acc * 31 + x : U32), Array.get(U32, m, U32.add(b, U32.inc(j))))

def cs.row(+rw: Nat, +b: U32, +acc: U32, m: Array<U32>) -> Fl2:
  cs.go(rw, b, 0, acc, Array.get(U32, m, b))

def cs.step(+rw: Nat, +rs: U32, +i: U32, f: Fl2) -> Fl2:
  match f:
    case Fl2{m, acc}:
      cs.row(rw, (i * rs : U32), acc, m)

def cs.rows(+n: Nat, +rw: Nat, +rs: U32, +i: U32, f: Fl2) -> U32:
  match n:
    case 0n:
      match f:
        case Fl2{m, acc}:
          acc
    case 1n+q:
      cs.rows(q, rw, rs, U32.inc(i), cs.step(rw, rs, i, f))

def cs.fin(+n: Nat, +rw: Nat, +rs: U32, st: St) -> U32:
  match st:
    case St{m, t}:
      cs.rows(n, rw, rs, 0, Fl2{m, 7})

def fl_m(f: Fl) -> Array<U32>:
  match f:
    case Fl{m, x}:
      m

def run(+n: U32, +t: U32) -> IO(Unit):
  +cw = U32.shrn((n + 3 : U32), 2n)
  +rwu = (cw + U32.shrn(t, 2n) : U32)
  +rw = U32.to_nat(rwu)
  +lrs = G.Vec.clog(rwu)
  +rs = U32.shln(1, lrs)
  m = fm.go(U32.to_nat(n), rw, rs, 0, Fl{Array.new(U32, (lrs + U32.log2(U32.max(n, 1)) + 1n : Nat), 0), 12345})
  tab = tb.go(65536n, 0, Array.new(U32, 16n, 0))
  do IO<Unit>:
    t0 : Nat <- IO.now()
    IO.print("checksum " ++ U32.show(cs.fin(U32.to_nat(n), rw, rs, gj(U32.to_nat(n), U32.to_nat(n), rw, rs, 0, St{fl_m(m), tab}))))
    t1 : Nat <- IO.now()
    IO.print("RESULT gj_arr n=" ++ U32.show(n) ++ " T=" ++ U32.show(t) ++ " words/row=" ++ U32.show(rwu) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> rest:
      run(rd(a, 142), rd(b, 1024))
    case _:
      run(142, 1024)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
