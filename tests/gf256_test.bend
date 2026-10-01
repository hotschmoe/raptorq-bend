# Tests for src/gf256.bend. Run: bend tests/gf256_test.bend
# Prints one line per section and ALL PASS; exits non-zero (IO.die) on failure.
import Base
import ../src/gf256.bend as G

# Checksums of the full 256x256 mul / div tables, computed independently by
# tools/gen_gf256.py (RFC tables == raptorq-rs == generated field).
# BEGIN GENERATED
def MUL_CHECKSUM() -> U32:
  3642126208

def DIV_CHECKSUM() -> U32:
  90472832
# END GENERATED

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# 0 when the check holds, 1 when it fails (so failures can be summed).
def fail(b: Bool) -> U32:
  match b:
    case True{}:
      0
    case False{}:
      1

def eq(a: U32, b: U32) -> U32:
  fail(U32.is_eq(a, b))

# Run f(a, b, acc) over all a, b in 0..255 (a outer, b inner), threading acc.
def inner(~f: @+a: U32 -> @+b: U32 -> @acc: U32 -> U32, n: Nat, +a: U32, +b: U32, acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      inner(~f, p, a, (b + 1 : U32), f(a, b, acc))

def outer(~f: @+a: U32 -> @+b: U32 -> @acc: U32 -> U32, n: Nat, +a: U32, acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      outer(~f, p, (a + 1 : U32), inner(~f, 256n, a, 0, acc))

def all_pairs(~f: @+a: U32 -> @+b: U32 -> @acc: U32 -> U32, acc: U32) -> U32:
  outer(~f, 256n, 0, acc)

# ---------------------------------------------------------------------------
# Scalar steps
# ---------------------------------------------------------------------------

def step_mul_slow(+a: U32, +b: U32, acc: U32) -> U32:
  (acc + eq(G.mul(a, b), G.mul_slow(a, b)) : U32)

def step_comm(+a: U32, +b: U32, acc: U32) -> U32:
  (acc + eq(G.mul(a, b), G.mul(b, a)) : U32)

def step_mul_hash(+a: U32, +b: U32, acc: U32) -> U32:
  ((acc * 31 : U32) + G.mul(a, b) : U32)

def step_div_hash(+a: U32, +b: U32, acc: U32) -> U32:
  match b:
    case 0:
      acc
    case _:
      ((acc * 31 : U32) + G.div(a, b) : U32)

# (a / b) * b == a, and a / b == a * inv(b), for b != 0
def step_div(+a: U32, +b: U32, acc: U32) -> U32:
  match b:
    case 0:
      acc
    case _:
      +d = G.div(a, b)
      (acc + eq(G.mul(d, b), a) + eq(d, G.mul(a, G.inv(b))) : U32)

# a * inv(a) == 1, alpha^log(a) == a, log(alpha^i) == i mod 255, for a != 0
def step_inv(+a: U32, +b: U32, acc: U32) -> U32:
  match a:
    case 0:
      acc
    case _:
      (acc + eq(G.mul(a, G.inv(a)), 1) + eq(G.oct_exp(G.oct_log(a)), a)
        + eq(G.oct_log(G.oct_exp(a)), (a % 255 : U32)) : U32)

# distributivity and associativity with c derived from (a, b)
def step_field(+a: U32, +b: U32, acc: U32) -> U32:
  +c = U32.and((a * 7 + b * 13 : U32), 255)
  +d1 = eq(G.mul(a, G.add(b, c)), G.add(G.mul(a, b), G.mul(a, c)))
  d2 = eq(G.mul(G.mul(a, b), c), G.mul(a, G.mul(b, c)))
  d3 = eq(G.mul(1, a), a)
  d4 = eq(G.add(G.add(a, b), b), a)
  (acc + d1 + d2 + d3 + d4 : U32)

# ---------------------------------------------------------------------------
# Packed words
# ---------------------------------------------------------------------------

def byte(+w: U32, k: Nat) -> U32:
  U32.and(U32.shrn(w, k), 255)

def pack4(b0: U32, b1: U32, b2: U32, b3: U32) -> U32:
  (U32.shln(b0, 24n) .|. U32.shln(b1, 16n) .|. U32.shln(b2, 8n) .|. b3 : U32)

# scalar reference: multiply each octet of w by c using the table mul
def mulw_ref(+c: U32, +w: U32) -> U32:
  pack4(G.mul(c, byte(w, 24n)), G.mul(c, byte(w, 16n)), G.mul(c, byte(w, 8n)), G.mul(c, byte(w, 0n)))

# every (c, octet) pair appears in every byte lane
def step_mulw(+c: U32, +b: U32, acc: U32) -> U32:
  +w = pack4(b, U32.and((b + 1 : U32), 255), U32.and((b + 2 : U32), 255), U32.and((b + 3 : U32), 255))
  +w2 = pack4(U32.and((b + 3 : U32), 255), b, U32.and((b + 2 : U32), 255), U32.and((b + 1 : U32), 255))
  (acc + eq(G.mulw(c, w), mulw_ref(c, w)) + eq(G.mulw(c, w2), mulw_ref(c, w2)) : U32)

# ---------------------------------------------------------------------------
# Vectors
# ---------------------------------------------------------------------------

# n pseudo-random words (LCG), deterministic
def words(n: Nat, +x: U32) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +y = (x * 1664525 + 1013904223 : U32)
      y <> words(p, y)

def list_eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{x, xt} Con{y, yt}:
      Bool.and(U32.is_eq(x, y), list_eq(xt, yt))
    case _ _:
      False{}

def zip_xor(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  match xs ys:
    case Con{x, xt} Con{y, yt}:
      (x .^. y : U32) <> zip_xor(xt, yt)
    case _ _:
      Nil{}

def zip_muladd(+c: U32, xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  match xs ys:
    case Con{x, xt} Con{y, yt}:
      (x .^. G.mulw(c, y) : U32) <> zip_muladd(c, xt, yt)
    case _ _:
      Nil{}

def map_mulw(+c: U32, xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, xt}:
      G.mulw(c, x) <> map_mulw(c, xt)

def tl(v: G.Vec) -> List<&2, U32>:
  G.Vec.to_list(v, Nil{})

# all vector ops for n words and scalar c
def check_vec(+n: Nat, +c: U32) -> U32:
  +a = words(n, 1)
  +s = words(n, 2)
  va = G.Vec.from_list(a)
  vs = G.Vec.from_list(s)
  +vb = G.Vec.from_list(a)
  +vt = G.Vec.from_list(s)
  r0 = fail(list_eq(tl(G.Vec.from_list(a)), a))
  r1 = fail(list_eq(tl(G.Vec.xor(va, vs)), zip_xor(a, s)))
  r2 = fail(list_eq(tl(G.Vec.muladd(c, vb, vt)), zip_muladd(c, a, s)))
  r3 = fail(list_eq(tl(G.Vec.scale(c, G.Vec.from_list(s))), map_mulw(c, s)))
  # dst ^= c*src applied twice restores dst (char 2)
  r4 = fail(list_eq(tl(G.Vec.muladd(c, G.Vec.muladd(c, G.Vec.from_list(a), G.Vec.from_list(s)), G.Vec.from_list(s))), a))
  # x ^ x == 0
  r5 = fail(list_eq(tl(G.Vec.xor(G.Vec.from_list(a), G.Vec.from_list(a))), map_mulw(0, a)))
  (r0 + r1 + r2 + r3 + r4 + r5 : U32)

def over_cs(+n: Nat, cs: List<&2, U32>, acc: U32) -> U32:
  match cs:
    case Nil{}:
      acc
    case Con{c, rest}:
      over_cs(n, rest, (acc + check_vec(n, c) : U32))

def over_n(+k: Nat, acc: U32) -> U32:
  match k:
    case 0n:
      acc
    case 1n+p:
      over_n(p, over_cs(k, [0, 1, 2, 3, 29, 142, 200, 255], acc))

# ---------------------------------------------------------------------------
# Known values from the RFC tables
# ---------------------------------------------------------------------------

def known() -> U32:
  (eq(G.oct_exp(0), 1) + eq(G.oct_exp(7), 128) + eq(G.oct_exp(8), 29)
   + eq(G.oct_exp(254), 142) + eq(G.oct_exp(255), 1) + eq(G.oct_exp(509), 142)
   + eq(G.oct_log(1), 0) + eq(G.oct_log(2), 1) + eq(G.oct_log(29), 8)
   + eq(G.oct_log(255), 175) + eq(G.oct_log(142), 254)
   + eq(G.mul(2, 128), 29) + eq(G.mul(3, 7), 9) + eq(G.mul(128, 128), 19)
   + eq(G.mul(0, 77), 0) + eq(G.mul(77, 0), 0) + eq(G.mul(1, 77), 77)
   + eq(G.div(29, 2), 128) + eq(G.div(0, 5), 0) + eq(G.inv(2), 142) + eq(G.inv(1), 1)
   + eq(G.add(5, 3), 6) + eq(G.alpha_pow(8), 29) : U32)

# ---------------------------------------------------------------------------

def section(name: String, fails: U32) -> IO(Unit):
  match fails:
    case 0:
      IO.print(name ++ ": ok")
    case _:
      IO.die(Unit, 1, name ++ ": FAILED, mismatches = " ++ U32.show(fails))

def main() -> IO(Unit):
  do IO<Unit>:
    section("known RFC values", known())
    section("mul == carry-less mul (65536 pairs)", all_pairs(~step_mul_slow, 0))
    section("mul commutative (65536 pairs)", all_pairs(~step_comm, 0))
    section("mul table checksum vs python", eq(all_pairs(~step_mul_hash, 0), MUL_CHECKSUM()))
    section("div table checksum vs python", eq(all_pairs(~step_div_hash, 0), DIV_CHECKSUM()))
    section("div/inv/log-exp (65536 pairs)", all_pairs(~step_div, all_pairs(~step_inv, 0)))
    section("distrib/assoc/identity/self-inverse", all_pairs(~step_field, 0))
    section("packed mulw == per-octet mul (all c, all octets)", all_pairs(~step_mulw, 0))
    section("Vec xor/muladd/scale/roundtrip (n=1..24)", over_n(24n, 0))
    IO.print("ALL PASS")
