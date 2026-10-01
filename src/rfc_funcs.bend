# RFC 6330 generators and derived parameters:
#   Rand[y,i,m] (5.3.5.1), Deg[v] (5.3.5.2), Tuple[K',X] (5.3.5.4),
#   K -> K' lookup (5.3.1 / 5.6) and L, P, P1, U, B (5.3.3.3).
#
# All arithmetic is U32.  Every operation is exact in 32 bits except the two
# the RFC itself defines modulo 2^32 (y = (B + X*A) % 2^32, and y + i in
# Rand, only ever used mod 256), which U32 wraparound implements verbatim.
import Base
import ./tables.bend as T

# ---------------------------------------------------------------------------
# Rand[y, i, m] (5.3.5.1)
# ---------------------------------------------------------------------------

# V0[x0] ^ V1[x1] ^ V2[x2] ^ V3[x3] with the four byte indexes (all < 256).
def rand.mix(+x0: U32, +x1: U32, +x2: U32, +x3: U32) -> U32:
  (T.V0(x0) .^. T.V1(x1) .^. T.V2(x2) .^. T.V3(x3) : U32)

def rand(+y: U32, +i: U32, +m: U32) -> U32:
  x0 = ((y + i : U32) .&. 255 : U32)
  x1 = (((y >> 8n : U32) + i : U32) .&. 255 : U32)
  x2 = (((y >> 16n : U32) + i : U32) .&. 255 : U32)
  x3 = (((y >> 24n : U32) + i : U32) .&. 255 : U32)
  (rand.mix(x0, x1, x2, x3) % m : U32)

# ---------------------------------------------------------------------------
# Deg[v] (5.3.5.2): min(d, W-2) where f[d-1] <= v < f[d]
# ---------------------------------------------------------------------------

def deg(+v: U32, +w: U32) -> U32:
  U32.min(T.deg_index(v), (w - 2 : U32))

# ---------------------------------------------------------------------------
# K -> K' and the derived parameters (5.3.3.3)
# ---------------------------------------------------------------------------

def params.go(+k: U32, ok: Bool) -> Maybe<&2, T.SP>:
  match ok:
    case True{}:
      Some{T.sp_row(k)}
    case False{}:
      None{}

# Table 2 row for the smallest K' >= k; None if k > 56403.
def params(+k: U32) -> Maybe<&2, T.SP>:
  params.go(k, U32.is_le(k, 56403))

def Kp(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      kp

def J(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      j

def S(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      s

def H(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      h

def W(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      w

# P1: smallest prime >= P (precomputed per row by tools/gen_tables.py).
def P1(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      p1

# L = K' + S + H
def L(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      (kp + s + h : U32)

# P = L - W
def P(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      (kp + s + h - w : U32)

# U = P - H
def U(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      (kp + s - w : U32)

# B = W - S
def B(sp: T.SP) -> U32:
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      (w - s : U32)

# ---------------------------------------------------------------------------
# Tuple[K', X] (5.3.5.4)
# ---------------------------------------------------------------------------

type Tup is Data:
  Tup{d: U32, a: U32, b: U32, d1: U32, a1: U32, b1: U32}

def tuple.d1.go(+x: U32, small: Bool) -> U32:
  match small:
    case True{}:
      (2 + rand(x, 3, 2) : U32)
    case False{}:
      2

# d1 = 2 + Rand[X,3,2] if d < 4 else 2
def tuple.d1(+d: U32, +x: U32) -> U32:
  tuple.d1.go(x, U32.is_lt(d, 4))

def tuple.fin(+y: U32, +w: U32, +p1: U32, +x: U32, +v: U32) -> Tup:
  +d = deg(v, w)
  a = (1 + rand(y, 1, (w - 1 : U32)) : U32)
  b = rand(y, 2, w)
  d1 = tuple.d1(d, x)
  a1 = (1 + rand(x, 4, (p1 - 1 : U32)) : U32)
  b1 = rand(x, 5, p1)
  Tup{d, a, b, d1, a1, b1}

def tuple.go(+j: U32, +w: U32, +p1: U32, +x: U32) -> Tup:
  # A = 53591 + J*997, bumped to odd; B = 10267*(J+1)
  aa = ((53591 + (j * 997 : U32) : U32) .|. 1 : U32)
  bb = (10267 * (j + 1 : U32) : U32)
  # y = (B + X*A) mod 2^32 -- U32 wraparound
  +y = (bb + (x * aa : U32) : U32)
  tuple.fin(y, w, p1, x, rand(y, 0, 1048576))

# Tuple[K', X] for the Table 2 row `sp` (K' = Kp(sp)).
def tuple(sp: T.SP, +x: U32) -> Tup:
  match sp:
    case T.SP{kp, +j, s, h, +w, +p1}:
      tuple.go(j, w, p1, x)
