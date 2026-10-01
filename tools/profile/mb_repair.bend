# Repair-symbol generation with flat Array<U32> symbols (pure Bend): all L intermediate symbols live in ONE flat
# Array<U32> (symbol c at offset c*W); each repair symbol XORs the real LT/PI terms (C.lt_terms) of its ISI into a
# fresh accumulator array.   T/4 = W must be a power of two here.
#   bend tools/profile/mb_repair.bend -o build/mb_repair ; ./build/mb_repair [--threads N] -- <K> <T octets> <N>
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as T
import ../../src/rfc_funcs.bend as R
import ../../src/constraints.bend as C

type Pr is Type:
  Pr{d: Array<U32>, s: Array<U32>}

# d[j] ^= big[b + j]  for j in 0..n-1
def xr.f2(+j: U32, s: Array<U32>, rd: Array<U32> & U32, x: U32) -> Pr:
  (d, y) = rd
  Pr{d[j] <- U32.xor(y, x), s}

def xr.f1(+j: U32, d: Array<U32>, rs: Array<U32> & U32) -> Pr:
  (s, x) = rs
  xr.f2(j, s, Array.get(U32, d, j), x)

def xr.step(+j: U32, +b: U32, p: Pr) -> Pr:
  Pr{d, s} = p
  xr.f1(j, d, Array.get(U32, s, U32.add(b, j)))

def xr.loop(+n: Nat, +j: U32, +b: U32, p: Pr) -> Pr:
  match n:
    case 0n:
      p
    case 1n+q:
      xr.loop(q, U32.inc(j), b, xr.step(j, b, p))

def fill(+n: Nat, +k: U32, +x: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+p:
      fill(p, U32.inc(k), (x * 1664525 + 1013904223 : U32), a[k] <- x)

def fromPr(p: Pr) -> Pr:
  p

def terms(ts: List<&2, Y.Term>, +w: Nat, +wu: U32, p: Pr) -> Pr:
  match ts:
    case Nil{}:
      p
    case Con{t, rest}:
      match t:
        case Y.Term{col, coef}:
          terms(rest, w, wu, xr.loop(w, 0, (col * wu : U32), p))

def sumw(+n: Nat, +j: U32, +acc: U32, r: Array<U32> & U32) -> U32:
  match n r:
    case 0n _:
      acc
    case 1n+q Tuple{a, x}:
      sumw(q, U32.inc(j), (acc * 31 + x : U32), Array.get(U32, a, U32.inc(j)))

def sumw2(+w: Nat, a: Array<U32>) -> U32:
  sumw(w, 0, 7, Array.get(U32, a, 0))

type Out is Type:
  Out{cs: U32, big: Array<U32>}

def one2(+w: Nat, +cs: U32, p: Pr) -> Out:
  match p:
    case Pr{d, s}:
      Out{(cs * 31 + sumw2(w, d) : U32), s}

def one1(+w: Nat, +wu: U32, +cs: U32, +ts: List<&2, Y.Term>, +lw: Nat, big: Array<U32>) -> Out:
  one2(w, cs, terms(ts, w, wu, Pr{Array.new(U32, lw, 0), big}))

def one(+esi: U32, +k: U32, +w: Nat, +wu: U32, +lw: Nat, +sp: T.SP, o: Out) -> Out:
  match o:
    case Out{cs, big}:
      one1(w, wu, cs, C.lt_terms(sp, C.isi_of(esi, k, R.Kp(sp))), lw, big)

def gen(+n: Nat, +esi: U32, +k: U32, +w: Nat, +wu: U32, +lw: Nat, +sp: T.SP, o: Out) -> Out:
  match n:
    case 0n:
      o
    case 1n+q:
      gen(q, U32.inc(esi), k, w, wu, lw, sp, one(esi, k, w, wu, lw, sp, o))

def fin(o: Out) -> U32:
  match o:
    case Out{cs, big}:
      cs

def sp_of.go(m: Maybe<&2, T.SP>) -> T.SP:
  match m:
    case Some{sp}:
      sp
    case None{}:
      T.SP{0, 0, 0, 0, 0, 0}

def cnt(+n: Nat, +esi: U32, +k: U32, +sp: T.SP, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+q:
      cnt(q, U32.inc(esi), k, sp, (acc + U32.from_nat(List.length(&2, Y.Term, C.lt_terms(sp, C.isi_of(esi, k, R.Kp(sp))))) : U32))

def run(+k: U32, +t: U32, +n: U32) -> IO(Unit):
  +sp = sp_of.go(R.params(k))
  +wu = U32.shrn(t, 2n)
  +w = U32.to_nat(wu)
  +lw = U32.log2(wu)
  big = fill(U32.to_nat((R.L(sp) * wu : U32)), 0, 12345, Array.new(U32, (U32.log2((R.L(sp) * wu : U32)) + 1n : Nat), 0))
  do IO<Unit>:
    IO.print("K=" ++ U32.show(k) ++ " L=" ++ U32.show(R.L(sp)) ++ " T=" ++ U32.show(t) ++ " total LT/PI terms for N symbols=" ++ U32.show(cnt(U32.to_nat(n), k, k, sp, 0)))
    t0 : Nat <- IO.now()
    IO.print("checksum " ++ U32.show(fin(gen(U32.to_nat(n), k, k, w, wu, lw, sp, Out{0, big}))))
    t1 : Nat <- IO.now()
    IO.print("RESULT repair_arr K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " N=" ++ U32.show(n) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> c <> rest:
      run(rd(a, 1000), rd(b, 1024), rd(c, 1000))
    case _:
      run(1000, 1024, 1000)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
