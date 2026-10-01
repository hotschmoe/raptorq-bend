# Pure-Bend flat-array symbol kernels: dst, src : Array<U32> (4 octets per slot, power-of-two slot count), in-place updates.
#   bend tools/profile/mb_arr.bend -o build/mb_arr ; ./build/mb_arr --threads 1 -- <words, power of 2> <ops> <variant>
# variants: 0 xor | 1 muladd, SWAR G.mulw | 2 muladd, bit-sliced with hoisted k_i | 3 muladd, 64K-entry product table (Array<U32>)
#           4 xor, 4-way unrolled | 5 muladd bit-sliced hoisted, 4-way unrolled
import Base
import ../../src/gf256.bend as G

type Pr is Type:
  Pr{d: Array<U32>, s: Array<U32>}

def fill(+n: Nat, +k: U32, +x: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+p:
      fill(p, U32.inc(k), (x * 1664525 + 1013904223 : U32), a[k] <- x)

# ---- xor ----------------------------------------------------------------------------------------------
# ---- helpers: a step reads s[j], then d[j], then writes d[j] --------------------------------------------
def xr.f2(+j: U32, s: Array<U32>, rd: Array<U32> & U32, x: U32) -> Pr:
  (d, y) = rd
  Pr{d[j] <- U32.xor(y, x), s}

def xr.f1(+j: U32, d: Array<U32>, rs: Array<U32> & U32) -> Pr:
  (s, x) = rs
  xr.f2(j, s, Array.get(U32, d, j), x)

def xr.step(+j: U32, p: Pr) -> Pr:
  Pr{d, s} = p
  xr.f1(j, d, Array.get(U32, s, j))

def xr.loop(+n: Nat, +j: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      xr.loop(q, U32.inc(j), xr.step(j, p))

# 4-way unrolled
def xr.loop4(+n: Nat, +j: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      xr.loop4(q, U32.add(j, 4), xr.step(U32.add(j, 3), xr.step(U32.add(j, 2), xr.step(U32.add(j, 1), xr.step(j, p)))))

# ---- muladd: SWAR G.mulw ------------------------------------------------------------------------------
def ma.f2(+j: U32, +c: U32, s: Array<U32>, rd: Array<U32> & U32, x: U32) -> Pr:
  (d, y) = rd
  Pr{d[j] <- U32.xor(y, G.mulw(c, x)), s}

def ma.f1(+j: U32, +c: U32, d: Array<U32>, rs: Array<U32> & U32) -> Pr:
  (s, x) = rs
  ma.f2(j, c, s, Array.get(U32, d, j), x)

def ma.step(+j: U32, +c: U32, p: Pr) -> Pr:
  Pr{d, s} = p
  ma.f1(j, c, d, Array.get(U32, s, j))

def ma.loop(+n: Nat, +j: U32, +c: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      ma.loop(q, U32.inc(j), c, ma.step(j, c, p))

# ---- muladd: bit-sliced, k_i = c * alpha^i hoisted --------------------------------------------------
def mk2(+k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, +w: U32) -> U32:
  ((U32.and(w, 16843009) * k0 : U32) .^. (U32.and(U32.shrn(w, 1n), 16843009) * k1 : U32) .^. (U32.and(U32.shrn(w, 2n), 16843009) * k2 : U32) .^. (U32.and(U32.shrn(w, 3n), 16843009) * k3 : U32) .^. (U32.and(U32.shrn(w, 4n), 16843009) * k4 : U32) .^. (U32.and(U32.shrn(w, 5n), 16843009) * k5 : U32) .^. (U32.and(U32.shrn(w, 6n), 16843009) * k6 : U32) .^. (U32.and(U32.shrn(w, 7n), 16843009) * k7 : U32) : U32)

def bs.f2(+j: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, s: Array<U32>, rd: Array<U32> & U32, x: U32) -> Pr:
  (d, y) = rd
  Pr{d[j] <- U32.xor(y, mk2(k0, k1, k2, k3, k4, k5, k6, k7, x)), s}

def bs.f1(+j: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, d: Array<U32>, rs: Array<U32> & U32) -> Pr:
  (s, x) = rs
  bs.f2(j, k0, k1, k2, k3, k4, k5, k6, k7, s, Array.get(U32, d, j), x)

def bs.step(+j: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, p: Pr) -> Pr:
  Pr{d, s} = p
  bs.f1(j, k0, k1, k2, k3, k4, k5, k6, k7, d, Array.get(U32, s, j))

def bs.loop(+n: Nat, +j: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      bs.loop(q, U32.inc(j), k0, k1, k2, k3, k4, k5, k6, k7, bs.step(j, k0, k1, k2, k3, k4, k5, k6, k7, p))

def bs.loop4(+n: Nat, +j: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      bs.loop4(q, U32.add(j, 4), k0, k1, k2, k3, k4, k5, k6, k7, bs.step(U32.add(j, 3), k0, k1, k2, k3, k4, k5, k6, k7, bs.step(U32.add(j, 2), k0, k1, k2, k3, k4, k5, k6, k7, bs.step(U32.add(j, 1), k0, k1, k2, k3, k4, k5, k6, k7, bs.step(j, k0, k1, k2, k3, k4, k5, k6, k7, p)))))

# ---- muladd: 64K-entry product table  T[(c << 8) | b] = c*b, threaded through the loop -------------------------
type Tp is Type:
  Tp{d: Array<U32>, s: Array<U32>, t: Array<U32>}

# 4 lookups per word, each get hands the table back
def tl.g4(+j: U32, d: Array<U32>, s: Array<U32>, +x: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Tp:
  (t, p0) = r
  Tp{d[j] <- U32.xor(y, (acc .|. p0 : U32)), s, t}

def tl.g3(+j: U32, +c8: U32, d: Array<U32>, s: Array<U32>, +x: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Tp:
  (t, p1) = r
  tl.g4(j, d, s, x, y, (acc .|. U32.shln(p1, 8n) : U32), Array.get(U32, t, (c8 + U32.and(x, 255) : U32)))

def tl.g2(+j: U32, +c8: U32, d: Array<U32>, s: Array<U32>, +x: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Tp:
  (t, p2) = r
  tl.g3(j, c8, d, s, x, y, (acc .|. U32.shln(p2, 16n) : U32), Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 8n), 255) : U32)))

def tl.g1(+j: U32, +c8: U32, d: Array<U32>, s: Array<U32>, +x: U32, +y: U32, +acc: U32, r: Array<U32> & U32) -> Tp:
  (t, p3) = r
  tl.g2(j, c8, d, s, x, y, U32.shln(p3, 24n), Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 16n), 255) : U32)))

def tl.f2(+j: U32, +c8: U32, s: Array<U32>, t: Array<U32>, +x: U32, rd: Array<U32> & U32) -> Tp:
  (d, y) = rd
  tl.g1(j, c8, d, s, x, y, 0, Array.get(U32, t, (c8 + U32.and(U32.shrn(x, 24n), 255) : U32)))

def tl.f1(+j: U32, +c8: U32, d: Array<U32>, t: Array<U32>, rs: Array<U32> & U32) -> Tp:
  (s, x) = rs
  tl.f2(j, c8, s, t, x, Array.get(U32, d, j))

def tl.step(+j: U32, +c8: U32, p: Tp) -> Tp:
  Tp{d, s, t} = p
  tl.f1(j, c8, d, t, Array.get(U32, s, j))

def tl.loop(+n: Nat, +j: U32, +c8: U32, p: Tp) -> Tp:
  match n:
    case 0n:
      p
    case 1n+q:
      tl.loop(q, U32.inc(j), c8, tl.step(j, c8, p))

# table construction: T[c*256+b] = mul(c, b)  (log/exp via G.mul, once)
def tb.go(+n: Nat, +i: U32, t: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      t
    case 1n+q:
      tb.go(q, U32.inc(i), t[i] <- G.mul(U32.shrn(i, 8n), U32.and(i, 255)))

# ---- drivers ------------------------------------------------------------------------------------------
def sum.go(+n: Nat, +j: U32, +acc: U32, r: Array<U32> & U32) -> U32:
  match n r:
    case 0n _:
      acc
    case 1n+q Tuple{a, x}:
      sum.go(q, U32.inc(j), (acc * 31 + x : U32), Array.get(U32, a, U32.inc(j)))

def sum(+n: Nat, a: Array<U32>) -> U32:
  sum.go(n, 0, 7, Array.get(U32, a, 0))

def cc(+i: U32) -> U32:
  ((i .&. 255 : U32) .|. 2 : U32)

def chain0(+n: Nat, +w: Nat, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      chain0(q, w, xr.loop(w, 0, p))

def chain4(+n: Nat, +w: Nat, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      chain4(q, w, xr.loop4(w, 0, p))

def chain1(+n: Nat, +w: Nat, +c: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      chain1(q, w, U32.inc(c), ma.loop(w, 0, cc(c), p))

def chain2(+n: Nat, +w: Nat, +c: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      +k0 = cc(c)
      +k1 = G.xtime(k0)
      +k2 = G.xtime(k1)
      +k3 = G.xtime(k2)
      +k4 = G.xtime(k3)
      +k5 = G.xtime(k4)
      +k6 = G.xtime(k5)
      +k7 = G.xtime(k6)
      chain2(q, w, U32.inc(c), bs.loop(w, 0, k0, k1, k2, k3, k4, k5, k6, k7, p))

def chain5(+n: Nat, +w: Nat, +c: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      +k0 = cc(c)
      +k1 = G.xtime(k0)
      +k2 = G.xtime(k1)
      +k3 = G.xtime(k2)
      +k4 = G.xtime(k3)
      +k5 = G.xtime(k4)
      +k6 = G.xtime(k5)
      +k7 = G.xtime(k6)
      chain5(q, w, U32.inc(c), bs.loop4(U32.to_nat(U32.shrn(U32.from_nat(w), 2n)), 0, k0, k1, k2, k3, k4, k5, k6, k7, p))

def chain3(+n: Nat, +w: Nat, +c: U32, p: Tp) -> Tp:
  match n:
    case 0n:
      p
    case 1n+q:
      chain3(q, w, U32.inc(c), tl.loop(w, 0, U32.shln(cc(c), 8n), p))

def fin(+w: Nat, p: Pr) -> U32:
  match p:
    case Pr{d, s}:
      sum(w, d)

def fin3(+w: Nat, p: Tp) -> U32:
  match p:
    case Tp{d, s, t}:
      sum(w, d)

def run3(+w: U32, +m: U32, d: Array<U32>, s: Array<U32>, t: Array<U32>) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(fin3(U32.to_nat(w), chain3(U32.to_nat(m), U32.to_nat(w), 3, Tp{d, s, t}))))
    t1 : Nat <- IO.now()
    IO.print("RESULT arr words=" ++ U32.show(w) ++ " ops=" ++ U32.show(m) ++ " variant=3 ms=" ++ Nat.show((t1 - t0 : Nat)))

def pick(+v: U32, +w: Nat, +m: Nat, p: Pr) -> Pr:
  match v:
    case 0:
      chain0(m, w, p)
    case 1:
      chain1(m, w, 3, p)
    case 2:
      chain2(m, w, 3, p)
    case 4:
      chain4(m, w, p)
    case _:
      chain5(m, w, 3, p)

def runv(+w: U32, +m: U32, +v: U32, d: Array<U32>, s: Array<U32>) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(fin(U32.to_nat(w), pick(v, U32.to_nat(w), U32.to_nat(m), Pr{d, s}))))
    t1 : Nat <- IO.now()
    IO.print("RESULT arr words=" ++ U32.show(w) ++ " ops=" ++ U32.show(m) ++ " variant=" ++ U32.show(v) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def dolog2(+w: U32) -> Nat:
  U32.log2(w)

def run(+w: U32, +m: U32, +v: U32) -> IO(Unit):
  match v:
    case 3:
      run3(w, m, fill(U32.to_nat(w), 0, 7, Array.new(U32, U32.log2(w), 0)), fill(U32.to_nat(w), 0, 99, Array.new(U32, U32.log2(w), 0)), tb.go(65536n, 0, Array.new(U32, 16n, 0)))
    case _:
      runv(w, m, v, fill(U32.to_nat(w), 0, 7, Array.new(U32, U32.log2(w), 0)), fill(U32.to_nat(w), 0, 99, Array.new(U32, U32.log2(w), 0)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> c <> rest:
      run(rd(a, 256), rd(b, 1000), rd(c, 0))
    case _:
      run(256, 1000, 0)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
