# Multiply-add kernels on ONE array (the arena setting: symbols and the 64K table share an Array<U32>), ns per word:
#   0 xor | 1 SWAR G.mulw (Flat.ma) | 2 64K table (Flat.tm) | 3 bit-sliced with hoisted c*alpha^i (defined here)
#   bend tools/profile/mb_arena.bend -o build/mb_arena ; taskset -c 11 ./build/mb_arena --threads 1 -- <words per op> <ops> <variant>
# ops cycle over 64 symbols (dst, src chosen by op number) in a 2^20-slot array, c varies per op.
import Base
import ../../src/gf256.bend as G
import ../../src/flat.bend as F

# ---- bit-sliced: d ^= c * s, k_i = c * alpha^i hoisted per op ---------------------------------------------------
def mk2(+k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, +w: U32) -> U32:
  ((U32.and(w, 16843009) * k0 : U32) .^. (U32.and(U32.shrn(w, 1n), 16843009) * k1 : U32) .^. (U32.and(U32.shrn(w, 2n), 16843009) * k2 : U32) .^. (U32.and(U32.shrn(w, 3n), 16843009) * k3 : U32) .^. (U32.and(U32.shrn(w, 4n), 16843009) * k4 : U32) .^. (U32.and(U32.shrn(w, 5n), 16843009) * k5 : U32) .^. (U32.and(U32.shrn(w, 6n), 16843009) * k6 : U32) .^. (U32.and(U32.shrn(w, 7n), 16843009) * k7 : U32) : U32)

def bs.f2(+j: U32, +db: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, +x: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, y) = rd
  Array.set(U32, a, (db + j : U32), U32.xor(y, mk2(k0, k1, k2, k3, k4, k5, k6, k7, x)))

def bs.f1(+j: U32, +db: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, rs: Array<U32> & U32) -> Array<U32>:
  (a, x) = rs
  bs.f2(j, db, k0, k1, k2, k3, k4, k5, k6, k7, x, Array.get(U32, a, (db + j : U32)))

def bs.loop(+n: Nat, +j: U32, +db: U32, +sb: U32, +k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      bs.loop(q, U32.inc(j), db, sb, k0, k1, k2, k3, k4, k5, k6, k7, bs.f1(j, db, k0, k1, k2, k3, k4, k5, k6, k7, Array.get(U32, a, (sb + j : U32))))

def bs.op(+c: U32, +w: Nat, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  +k1 = G.xtime(c)
  +k2 = G.xtime(k1)
  +k3 = G.xtime(k2)
  +k4 = G.xtime(k3)
  +k5 = G.xtime(k4)
  +k6 = G.xtime(k5)
  +k7 = G.xtime(k6)
  bs.loop(w, 0, db, sb, c, k1, k2, k3, k4, k5, k6, k7, a)

def fill(+n: Nat, +k: U32, +x: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+p:
      fill(p, U32.inc(k), (x * 1664525 + 1013904223 : U32), Array.set(U32, a, k, x))

def one(+v: U32, +c: U32, +w: Nat, +db: U32, +sb: U32, a: Array<U32>) -> Array<U32>:
  match v:
    case 0:
      F.Flat.xr.loop(w, 0, db, sb, a)
    case 1:
      F.Flat.ma.loop(w, 0, db, sb, c, a)
    case 2:
      F.Flat.tm.loop(w, 0, db, sb, U32.shln(c, 8n), a)
    case _:
      bs.op(c, w, db, sb, a)

# symbols at 65536 + s * wu, 64 of them; op i: dst = i mod 64, src = (i * 7 + 3) mod 64
def chain(+v: U32, +n: Nat, +i: U32, +w: Nat, +wu: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      chain(v, q, U32.inc(i), w, wu, one(v, (U32.and(i, 253) .|. 2 : U32), w, (65536 + U32.and(i, 63) * wu : U32), (65536 + U32.and((i * 7 + 3 : U32), 63) * wu : U32), a))

def ck.fin(r: Array<U32> & U32) -> U32:
  (a, x) = r
  x

def run(+wu: U32, +m: U32, +v: U32) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(ck.fin(Array.get(U32, chain(v, U32.to_nat(m), 0, U32.to_nat(wu), wu, fill(U32.to_nat((64 * wu : U32)), 65536, 7, F.Flat.table(Array.new(U32, 20n, 0)))), 65536))))
    +t1 : Nat <- IO.now()
    IO.print("RESULT arena words=" ++ U32.show(wu) ++ " ops=" ++ U32.show(m) ++ " variant=" ++ U32.show(v) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> c <> rest:
      run(rd(a, 256), rd(b, 10000), rd(c, 2))
    case _:
      run(256, 10000, 2)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
