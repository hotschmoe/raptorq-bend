# Micro-benchmark: alternative GF(256) word-multiply kernels inside the same tree walk as Vec.muladd (1 thread).
#   bend tools/profile/mb_mulw.bend -o build/mb_mulw ; ./build/mb_mulw -- <words> <ops> <variant>
# variants: 0 = current mulw (Nat-fuel SWAR loop)  1 = unrolled SWAR  2 = bit-sliced, k_i = c*alpha^i hoisted per call
#           3 = log/exp lookup per octet (G.mul)    4 = control (xor only, tree walk)  5 = c==1 style xor via muladd walker
#           6 = 4-bit-sliced 2 table words per nibble (see mulw6)
# (generated once by a throw-away script; edit by hand)
import Base
import ../../src/gf256.bend as G

def words(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      words(p, (x * 1664525 + 1013904223 : U32), x <> acc)

def sum(v: G.Vec) -> U32:
  match v:
    case G.VNode{l, r}:
      (sum(l) + sum(r) : U32)
    case G.VWord{w}:
      w
    case G.VNil{}:
      0

def xt(+w: U32) -> U32:
  G.xtime4(w)

def bitm(+c: U32, +w: U32, +s: U32) -> U32:
  (0 - U32.and(U32.shrn(c, U32.to_nat(s)), 1) : U32)

# unrolled SWAR: acc = sum over bits j of c of alpha^j * w
def mulw1(+c: U32, +w: U32) -> U32:
  +w1 = xt(w)
  +w2 = xt(w1)
  +w3 = xt(w2)
  +w4 = xt(w3)
  +w5 = xt(w4)
  +w6 = xt(w5)
  +w7 = xt(w6)
  (U32.and((0 - U32.and(c, 1) : U32), w) .^. U32.and((0 - U32.and(U32.shrn(c, 1n), 1) : U32), w1) .^. U32.and((0 - U32.and(U32.shrn(c, 2n), 1) : U32), w2) .^. U32.and((0 - U32.and(U32.shrn(c, 3n), 1) : U32), w3) .^. U32.and((0 - U32.and(U32.shrn(c, 4n), 1) : U32), w4) .^. U32.and((0 - U32.and(U32.shrn(c, 5n), 1) : U32), w5) .^. U32.and((0 - U32.and(U32.shrn(c, 6n), 1) : U32), w6) .^. U32.and((0 - U32.and(U32.shrn(c, 7n), 1) : U32), w7) : U32)

# bit-sliced: octet b = sum_i bit_i(b) alpha^i  =>  c*b = xor_i bit_i(b) * (c alpha^i); k_i hoisted
def mulw2(+k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, +w: U32) -> U32:
  ((U32.and(w, 16843009) * k0 : U32) .^. (U32.and(U32.shrn(w, 1n), 16843009) * k1 : U32) .^. (U32.and(U32.shrn(w, 2n), 16843009) * k2 : U32) .^. (U32.and(U32.shrn(w, 3n), 16843009) * k3 : U32) .^. (U32.and(U32.shrn(w, 4n), 16843009) * k4 : U32) .^. (U32.and(U32.shrn(w, 5n), 16843009) * k5 : U32) .^. (U32.and(U32.shrn(w, 6n), 16843009) * k6 : U32) .^. (U32.and(U32.shrn(w, 7n), 16843009) * k7 : U32) : U32)

def mulw3(+c: U32, +w: U32) -> U32:
  (U32.shln(G.mul(c, U32.and(U32.shrn(w, 24n), 255)), 24n) .|. U32.shln(G.mul(c, U32.and(U32.shrn(w, 16n), 255)), 16n) .|. U32.shln(G.mul(c, U32.and(U32.shrn(w, 8n), 255)), 8n) .|. G.mul(c, U32.and(w, 255)) : U32)

def wk0(+c: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match dst src:
    case G.VNode{dl, dr} G.VNode{sl, sr}:
      G.VNode{wk0(c, dl, sl), wk0(c, dr, sr)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, G.mulw(c, y))}
    case x _:
      x

def wk1(+c: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match dst src:
    case G.VNode{dl, dr} G.VNode{sl, sr}:
      G.VNode{wk1(c, dl, sl), wk1(c, dr, sr)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, mulw1(c, y))}
    case x _:
      x

def wk2(+k0: U32, +k1: U32, +k2: U32, +k3: U32, +k4: U32, +k5: U32, +k6: U32, +k7: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match dst src:
    case G.VNode{dl, dr} G.VNode{sl, sr}:
      G.VNode{wk2(k0, k1, k2, k3, k4, k5, k6, k7, dl, sl), wk2(k0, k1, k2, k3, k4, k5, k6, k7, dr, sr)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, mulw2(k0, k1, k2, k3, k4, k5, k6, k7, y))}
    case x _:
      x

def wk3(+c: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match dst src:
    case G.VNode{dl, dr} G.VNode{sl, sr}:
      G.VNode{wk3(c, dl, sl), wk3(c, dr, sr)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, mulw3(c, y))}
    case x _:
      x

def wk4(+c: U32, dst: G.Vec, src: G.Vec) -> G.Vec:
  match dst src:
    case G.VNode{dl, dr} G.VNode{sl, sr}:
      G.VNode{wk4(c, dl, sl), wk4(c, dr, sr)}
    case G.VWord{x} G.VWord{y}:
      G.VWord{U32.xor(x, y)}
    case x _:
      x


def pow2k(+n: Nat, +c: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      pow2k(p, G.xtime(c), c <> acc)

def chain(n: Nat, +v: U32, +c: U32, acc: G.Vec, +src: G.Vec) -> G.Vec:
  match n:
    case 0n:
      acc
    case 1n+p:
      match v:
        case 0:
          +cc = ((c .&. 255 : U32) .|. 2 : U32)
          chain(p, v, (c + 1 : U32), wk0(cc, acc, src), src)
        case 1:
          +cc = ((c .&. 255 : U32) .|. 2 : U32)
          chain(p, v, (c + 1 : U32), wk1(cc, acc, src), src)
        case 2:
          +cc = ((c .&. 255 : U32) .|. 2 : U32)
          +k1 = G.xtime(cc)
          +k2 = G.xtime(k1)
          +k3 = G.xtime(k2)
          +k4 = G.xtime(k3)
          +k5 = G.xtime(k4)
          +k6 = G.xtime(k5)
          +k7 = G.xtime(k6)
          chain(p, v, (c + 1 : U32), wk2(cc, k1, k2, k3, k4, k5, k6, k7, acc, src), src)
        case 3:
          +cc = ((c .&. 255 : U32) .|. 2 : U32)
          chain(p, v, (c + 1 : U32), wk3(cc, acc, src), src)
        case _:
          +cc = ((c .&. 255 : U32) .|. 2 : U32)
          chain(p, v, (c + 1 : U32), wk4(cc, acc, src), src)

def run(+w: U32, +m: U32, +v: U32) -> IO(Unit):
  +a = G.Vec.from_list(words(U32.to_nat(w), 7, Nil{}))
  +b = G.Vec.from_list(words(U32.to_nat(w), 99, Nil{}))
  do IO<Unit>:
    IO.print("warm " ++ U32.show((sum(a) + sum(b) : U32)))
    t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(sum(chain(U32.to_nat(m), v, 3, a, b))))
    t1 : Nat <- IO.now()
    IO.print("RESULT words=" ++ U32.show(w) ++ " ops=" ++ U32.show(m) ++ " variant=" ++ U32.show(v) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> c <> rest:
      run(rd(a, 64), rd(b, 1000), rd(c, 0))
    case _:
      run(64, 1000, 0)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
