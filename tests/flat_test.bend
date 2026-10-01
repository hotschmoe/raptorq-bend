# Flat (src/flat.bend): Vec <-> Array<U32> round trips (shape included), slice kernels vs the Vec ops, and flat encoding
# symbols vs the per-ESI tree path (Codec.symbol), for T that is / is not a multiple of 4.
# Run: bend tests/flat_test.bend      Prints one line per section and ALL PASS; exits 1 on failure.
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/flat.bend as F
import ../src/raptorq.bend as Q

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def words.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      words.go(p, lcg(x), x <> acc)

def vec_of(+n: U32, +seed: U32) -> G.Vec:
  G.Vec.from_list(words.go(U32.to_nat(n), seed, []))

# structural equality (shape included)
def vec_eq(a: G.Vec, b: G.Vec) -> Bool:
  match a b:
    case G.VNil{} G.VNil{}:
      True{}
    case G.VWord{x} G.VWord{y}:
      U32.is_eq(x, y)
    case G.VNode{al, ar} G.VNode{bl, br}:
      band(vec_eq(al, bl), vec_eq(ar, br))
    case _ _:
      False{}

def lst_eq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(U32.is_eq(x, y), lst_eq(xs, ys))
    case _ _:
      False{}

def syms_eq(a: List<&2, G.Vec>, b: List<&2, G.Vec>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(vec_eq(x, y), syms_eq(xs, ys))
    case _ _:
      False{}

# ---- round trips ------------------------------------------------------------------------------------------------------
def rt(+n: U32) -> Bool:
  +v = vec_of(n, (n * 7 + 1 : U32))
  vec_eq(v, F.Flat.to_vec(n, F.Flat.of_vec(v)))

# the words land at base.. and nothing else moves
def rt_at(+n: U32, +base: U32) -> Bool:
  +v = vec_of(n, (n * 7 + base : U32))
  +w = vec_of(n, 12345)
  a = F.Flat.put_vec(w, 200, F.Flat.put_vec(v, base, Array.new(U32, 12n, 0)))
  vec_eq(v, F.Flat.bv_vec(F.Flat.get_vec(a, base, n)))

def rt_all(n: Nat, +i: U32, acc: Bool) -> Bool:
  match n:
    case 0n:
      acc
    case 1n+p:
      rt_all(p, U32.inc(i), band(acc, rt(i)))

# ---- kernels vs Vec ops: dst at 0, src at 8 (n words each) ------------------------------------------------------------
def two(+n: U32, +x: G.Vec, +y: G.Vec) -> Array<U32>:
  F.Flat.put_vec(y, 8, F.Flat.put_vec(x, 0, Array.new(U32, 5n, 0)))

def k_xor(+n: U32, +x: G.Vec, +y: G.Vec) -> Bool:
  vec_eq(G.Vec.xor(x, y), F.Flat.to_vec(n, F.Flat.xr.loop(U32.to_nat(n), 0, 0, 8, two(n, x, y))))

def k_ma(+n: U32, +c: U32, +x: G.Vec, +y: G.Vec) -> Bool:
  vec_eq(G.Vec.muladd(c, x, y), F.Flat.to_vec(n, F.Flat.ma.loop(U32.to_nat(n), 0, 0, 8, c, two(n, x, y))))

def k_ms(+n: U32, +c: U32, +y: G.Vec) -> Bool:
  vec_eq(G.Vec.scale(c, y), F.Flat.to_vec(n, F.Flat.ms.loop(U32.to_nat(n), 0, 0, 8, c, two(n, G.Vec.zeros(y), y))))

def k_cp(+n: U32, +x: G.Vec, +y: G.Vec) -> Bool:
  vec_eq(y, F.Flat.to_vec(n, F.Flat.cp.loop(U32.to_nat(n), 0, 0, 8, two(n, x, y))))

def k_zr(+n: U32, +x: G.Vec) -> Bool:
  vec_eq(G.Vec.zeros(x), F.Flat.to_vec(n, F.Flat.zr.loop(U32.to_nat(n), 0, 0, two(n, x, x))))

def kern(+n: U32, +c: U32) -> Bool:
  +x = vec_of(n, 99)
  +y = vec_of(n, 4242)
  band(k_xor(n, x, y), band(k_ma(n, c, x, y), band(k_ms(n, c, y), band(k_cp(n, x, y), k_zr(n, x)))))

def kern_all(n: Nat, +i: U32, acc: Bool) -> Bool:
  match n:
    case 0n:
      acc
    case 1n+p:
      kern_all(p, U32.inc(i), band(acc, band(kern((U32.and(i, 7) + 1 : U32), (i * 37 + 2 : U32)), kern((U32.and(i, 7) + 1 : U32), 255))))

# ---- flat encoding symbols == the per-ESI tree path --------------------------------------------------------------------
def bytes.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      bytes.go(p, lcg(x), U32.shrn(lcg(x), 24n) <> acc)

def per_esi(n: Nat, +i: U32, +e: Q.Enc, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      acc
    case 1n+p:
      per_esi(p, (i - 1 : U32), e, Q.Codec.symbol(e, i) <> acc)

def enc_cmp(m: Maybe<&2, Q.Enc>, +k: U32, +n: U32) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{+e}:
      band(syms_eq(Q.Codec.symbols(e, 0, n), per_esi(U32.to_nat(n), (n - 1 : U32), e, [])), syms_eq(Q.Codec.symbols(e, (k + 3 : U32), 5), per_esi(5n, (k + 7 : U32), e, [])))

def enc_case(+k: U32, +t: U32) -> Bool:
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  enc_cmp(Q.Codec.encoder(k, t, Q.Codec.split(data, t)), k, (k + 30 : U32))

def check(b: Bool, name: String) -> IO(U32):
  match b:
    case True{}:
      do IO<U32>:
        IO.print("PASS " ++ name)
        IO.pure(U32, 0)
    case False{}:
      do IO<U32>:
        IO.print("FAIL " ++ name)
        IO.pure(U32, 1)

def fin(+n: U32) -> IO(Unit):
  match n:
    case 0:
      IO.print("ALL PASS")
    case _:
      IO.die(Unit, 1, "FAILURES: " ++ U32.show(n))

def main() -> IO(Unit):
  do IO<Unit>:
    a : U32 <- check(rt_all(41n, 0, True{}), "Vec -> array -> Vec round trip, 0..40 words (shape included)")
    b : U32 <- check(band(rt(255), band(rt(256), band(rt(257), rt(1000)))), "round trip 255, 256, 257, 1000 words")
    c : U32 <- check(band(rt_at(1, 3), band(rt_at(5, 3), band(rt_at(5, 16), rt_at(7, 24)))), "put_vec / get_vec at an offset")
    d : U32 <- check(kern_all(24n, 0, True{}), "xor / copy / zero / mulw kernels == Vec.xor / scale / muladd")
    e : U32 <- check(band(enc_case(10, 16), band(enc_case(10, 5), band(enc_case(26, 4), enc_case(50, 20)))), "flat Codec.symbols == per-ESI Codec.symbol (K=10,26,50; T=16,5,4,20)")
    f : U32 <- check(band(enc_case(100, 64), enc_case(8, 1024)), "flat Codec.symbols, K=100 T=64, K=8 T=1024")
    fin((a + b + c + d + e + f : U32))
