import Base
import ./src/gf256.bend as G
import ./src/laws_defs.bend as D
import ./src/types.bend as Y
import ./src/solver.bend as S
import ./src/laws_verify.bend as V
import ./src/raptorq.bend as Q
import ./src/rfc_funcs.bend as R
import ./src/tables.bend as T
import ./LAWS.bend as Laws

# ---- generic helpers -------------------------------------------------------

def vnode_cong(a: G.Vec, b: G.Vec, c: G.Vec, d: G.Vec, ea: {a == c : G.Vec}, eb: {b == d : G.Vec}) -> {G.VNode{a, b} == G.VNode{c, d} : G.Vec}:
  %ea : {G.VNode{a, b} == G.VNode{_, d} : G.Vec}
  %eb : {G.VNode{a, b} == G.VNode{a, _} : G.Vec}
  {==}

def vword_cong(a: U32, b: U32, e: {a == b : U32}) -> {G.VWord{a} == G.VWord{b} : G.Vec}:
  %e : {G.VWord{a} == G.VWord{_} : G.Vec}
  {==}

def bool_xor_assoc(+a: Bool, +b: Bool, +c: Bool) -> {Bool.xor(Bool.xor(a, b), c) == Bool.xor(a, Bool.xor(b, c)) : Bool}:
  match a b c:
    case False{} False{} False{}:
      {==}
    case False{} False{} True{}:
      {==}
    case False{} True{} False{}:
      {==}
    case False{} True{} True{}:
      {==}
    case True{} False{} False{}:
      {==}
    case True{} False{} True{}:
      {==}
    case True{} True{} False{}:
      {==}
    case True{} True{} True{}:
      {==}

def wcon_cong(p: Nat, h: Bool, a: Word(p), b: Word(p), e: {a == b : Word(p)}) -> {WCon{h, a} == WCon{h, b} : Word(1n+p)}:
  Equal.cong(Word(p), Word(1n+p), w => WCon{h, w}, a, b, e)

def word_xor_assoc(+n: Nat, +a: Word(n), +b: Word(n), +c: Word(n)) -> {Word.xor(n, Word.xor(n, a, b), c) == Word.xor(n, a, Word.xor(n, b, c)) : Word(n)}:
  match n:
    case 0n:
      match a b c:
        case WNil{} WNil{} WNil{}:
          {==}
    case 1n++p:
      match a b c:
        case WCon{ah, at} WCon{bh, bt} WCon{ch, ct}:
          %bool_xor_assoc(ah, bh, ch) : {WCon{Bool.xor(Bool.xor(ah, bh), ch), Word.xor(p, Word.xor(p, at, bt), ct)} == WCon{_, Word.xor(p, at, Word.xor(p, bt, ct))} : Word(1n+p)}
          wcon_cong(p, Bool.xor(Bool.xor(ah, bh), ch), Word.xor(p, Word.xor(p, at, bt), ct), Word.xor(p, at, Word.xor(p, bt, ct)), word_xor_assoc(p, at, bt, ct))

def Laws.add_assoc(a, b, c):
  match a b c:
    case U32{x} U32{y} U32{z}:
      Equal.cong(Word(32n), U32, w => U32{w}, Word.xor(32n, Word.xor(32n, x, y), z),
        Word.xor(32n, x, Word.xor(32n, y, z)), word_xor_assoc(32n, x, y, z))

# ---- G.Vec.xor ------------------------------------------------------------

# xor at fork depth 0: the semantics; the fork depth only schedules work
def x0(a: G.Vec, b: G.Vec) -> G.Vec:
  G.Vec.xor.go(0n, a, b)

def same_refl(+a: G.Vec) -> D.Same(a, a):
  match a:
    case G.VNil{}:
      Unit{}
    case G.VWord{w}:
      Unit{}
    case G.VNode{+l, +r}:
      (same_refl(l), same_refl(r))

# the fork depth does not change the result
def xor_indep(+fk: Nat, +a: G.Vec, +b: G.Vec) -> {G.Vec.xor.go(fk, a, b) == x0(a, b) : G.Vec}:
  match fk:
    case 0n:
      {==}
    case 1n+q:
      match a b:
        case G.VNil{} G.VNil{}:
          {==}
        case G.VNil{} G.VWord{y}:
          {==}
        case G.VNil{} G.VNode{bl, br}:
          {==}
        case G.VWord{x} G.VNil{}:
          {==}
        case G.VWord{x} G.VWord{y}:
          {==}
        case G.VWord{x} G.VNode{bl, br}:
          {==}
        case G.VNode{al, ar} G.VNil{}:
          {==}
        case G.VNode{al, ar} G.VWord{y}:
          {==}
        case G.VNode{al, ar} G.VNode{bl, br}:
          vnode_cong(G.Vec.xor.go(q, al, bl), G.Vec.xor.go(q, ar, br), x0(al, bl), x0(ar, br), xor_indep(q, al, bl), xor_indep(q, ar, br))

def xor_eq0(+a: G.Vec, +b: G.Vec) -> {G.Vec.xor(a, b) == x0(a, b) : G.Vec}:
  xor_indep(G.Vec.fork_levels(a), a, b)

def xor_zero_go(+a: G.Vec, +fk: Nat) -> {G.Vec.xor.go(fk, a, G.Vec.zeros.go(fk, a)) == a : G.Vec}:
  match a:
    case G.VNil{}:
      match fk:
        case 0n:
          {==}
        case 1n+q:
          {==}
    case G.VWord{w}:
      match fk:
        case 0n:
          vword_cong(G.add(w, 0), w, G.add_zero(w))
        case 1n+q:
          vword_cong(G.add(w, 0), w, G.add_zero(w))
    case G.VNode{l, r}:
      match fk:
        case 0n:
          vnode_cong(G.Vec.xor.go(0n, l, G.Vec.zeros.go(0n, l)), G.Vec.xor.go(0n, r, G.Vec.zeros.go(0n, r)), l, r, xor_zero_go(l, 0n), xor_zero_go(r, 0n))
        case 1n+q:
          vnode_cong(G.Vec.xor.go(q, l, G.Vec.zeros.go(q, l)), G.Vec.xor.go(q, r, G.Vec.zeros.go(q, r)), l, r, xor_zero_go(l, q), xor_zero_go(r, q))

def xor_self_go(+a: G.Vec, +fk: Nat) -> {G.Vec.xor.go(fk, a, a) == G.Vec.zeros.go(fk, a) : G.Vec}:
  match a:
    case G.VNil{}:
      match fk:
        case 0n:
          {==}
        case 1n+q:
          {==}
    case G.VWord{w}:
      match fk:
        case 0n:
          vword_cong(G.add(w, w), 0, G.add_self(w))
        case 1n+q:
          vword_cong(G.add(w, w), 0, G.add_self(w))
    case G.VNode{l, r}:
      match fk:
        case 0n:
          vnode_cong(G.Vec.xor.go(0n, l, l), G.Vec.xor.go(0n, r, r), G.Vec.zeros.go(0n, l), G.Vec.zeros.go(0n, r), xor_self_go(l, 0n), xor_self_go(r, 0n))
        case 1n+q:
          vnode_cong(G.Vec.xor.go(q, l, l), G.Vec.xor.go(q, r, r), G.Vec.zeros.go(q, l), G.Vec.zeros.go(q, r), xor_self_go(l, q), xor_self_go(r, q))

def Laws.xor_self(a):
  xor_self_go(a, G.Vec.fork_levels(a))

def Laws.xor_zero(a):
  xor_zero_go(a, G.Vec.fork_levels(a))

def xor_comm0(+a: G.Vec, +b: G.Vec, s: D.Same(a, b)) -> {x0(a, b) == x0(b, a) : G.Vec}:
  match a b:
    case G.VNil{} G.VNil{}:
      {==}
    case G.VNil{} G.VWord{y}:
      match s:
    case G.VNil{} G.VNode{bl, br}:
      match s:
    case G.VWord{x} G.VNil{}:
      match s:
    case G.VWord{x} G.VWord{y}:
      vword_cong(G.add(x, y), G.add(y, x), G.add_comm(x, y))
    case G.VWord{x} G.VNode{bl, br}:
      match s:
    case G.VNode{al, ar} G.VNil{}:
      match s:
    case G.VNode{al, ar} G.VWord{y}:
      match s:
    case G.VNode{al, ar} G.VNode{bl, br}:
      (sl, sr) = s
      vnode_cong(x0(al, bl), x0(ar, br), x0(bl, al), x0(br, ar), xor_comm0(al, bl, sl), xor_comm0(ar, br, sr))

def Laws.xor_comm(a, b, s):
  Equal.trans(G.Vec, G.Vec.xor(a, b), x0(a, b), G.Vec.xor(b, a), xor_eq0(a, b),
    Equal.trans(G.Vec, x0(a, b), x0(b, a), G.Vec.xor(b, a), xor_comm0(a, b, s),
      Equal.sym(G.Vec, G.Vec.xor(b, a), x0(b, a), xor_eq0(b, a))))

def xor_assoc0.c(+a: G.Vec, +b: G.Vec, +c: G.Vec, s1: D.Same(a, b), s2: D.Same(b, c)) -> {x0(x0(a, b), c) == x0(a, x0(b, c)) : G.Vec}:
  match a b c:
    case G.VNil{} G.VNil{} G.VNil{}:
      {==}
    case G.VNil{} G.VNil{} G.VWord{z}:
      match s2:
    case G.VNil{} G.VNil{} G.VNode{cl, cr}:
      match s2:
    case G.VWord{x} G.VWord{y} G.VNil{}:
      match s2:
    case G.VWord{x} G.VWord{y} G.VWord{z}:
      vword_cong(G.add(G.add(x, y), z), G.add(x, G.add(y, z)), Laws.add_assoc(x, y, z))
    case G.VWord{x} G.VWord{y} G.VNode{cl, cr}:
      match s2:
    case G.VNode{al, ar} G.VNode{bl, br} G.VNil{}:
      match s2:
    case G.VNode{al, ar} G.VNode{bl, br} G.VWord{z}:
      match s2:
    case G.VNode{al, ar} G.VNode{bl, br} G.VNode{cl, cr}:
      (s1l, s1r) = s1
      (s2l, s2r) = s2
      vnode_cong(x0(x0(al, bl), cl), x0(x0(ar, br), cr), x0(al, x0(bl, cl)), x0(ar, x0(br, cr)),
        xor_assoc0.c(al, bl, cl, s1l, s2l), xor_assoc0.c(ar, br, cr, s1r, s2r))
    case G.VNil{} G.VWord{y} _:
      match s1:
    case G.VNil{} G.VNode{bl, br} _:
      match s1:
    case G.VWord{x} G.VNil{} _:
      match s1:
    case G.VWord{x} G.VNode{bl, br} _:
      match s1:
    case G.VNode{al, ar} G.VNil{} _:
      match s1:
    case G.VNode{al, ar} G.VWord{y} _:
      match s1:

def Laws.xor_assoc(a, b, c, s1, s2):
  Equal.trans(G.Vec, G.Vec.xor(G.Vec.xor(a, b), c), x0(G.Vec.xor(a, b), c), G.Vec.xor(a, G.Vec.xor(b, c)),
    xor_eq0(G.Vec.xor(a, b), c),
    Equal.trans(G.Vec, x0(G.Vec.xor(a, b), c), x0(x0(a, b), c), G.Vec.xor(a, G.Vec.xor(b, c)),
      Equal.cong(G.Vec, G.Vec, t => x0(t, c), G.Vec.xor(a, b), x0(a, b), xor_eq0(a, b)),
      Equal.trans(G.Vec, x0(x0(a, b), c), x0(a, x0(b, c)), G.Vec.xor(a, G.Vec.xor(b, c)),
        xor_assoc0.c(a, b, c, s1, s2),
        Equal.trans(G.Vec, x0(a, x0(b, c)), x0(a, G.Vec.xor(b, c)), G.Vec.xor(a, G.Vec.xor(b, c)),
          Equal.cong(G.Vec, G.Vec, t => x0(a, t), x0(b, c), G.Vec.xor(b, c), Equal.sym(G.Vec, G.Vec.xor(b, c), x0(b, c), xor_eq0(b, c))),
          Equal.sym(G.Vec, G.Vec.xor(a, G.Vec.xor(b, c)), x0(a, G.Vec.xor(b, c)), xor_eq0(a, G.Vec.xor(b, c)))))))

def add_inv(+x: U32, +y: U32) -> {G.add(G.add(x, y), y) == x : U32}:
  Equal.trans(U32, G.add(G.add(x, y), y), G.add(x, G.add(y, y)), x, Laws.add_assoc(x, y, y),
    Equal.trans(U32, G.add(x, G.add(y, y)), G.add(x, 0), x,
      Equal.cong(U32, U32, t => G.add(x, t), G.add(y, y), 0, G.add_self(y)),
      G.add_zero(x)))

def xor_inv0(+a: G.Vec, +b: G.Vec) -> {x0(x0(a, b), b) == a : G.Vec}:
  match a b:
    case G.VNil{} G.VNil{}:
      {==}
    case G.VNil{} G.VWord{y}:
      {==}
    case G.VNil{} G.VNode{bl, br}:
      {==}
    case G.VWord{x} G.VNil{}:
      {==}
    case G.VWord{x} G.VWord{y}:
      vword_cong(G.add(G.add(x, y), y), x, add_inv(x, y))
    case G.VWord{x} G.VNode{bl, br}:
      {==}
    case G.VNode{al, ar} G.VNil{}:
      {==}
    case G.VNode{al, ar} G.VWord{y}:
      {==}
    case G.VNode{al, ar} G.VNode{bl, br}:
      vnode_cong(x0(x0(al, bl), bl), x0(x0(ar, br), br), al, ar, xor_inv0(al, bl), xor_inv0(ar, br))

def Laws.xor_inv(a, b):
  Equal.trans(G.Vec, G.Vec.xor(G.Vec.xor(a, b), b), x0(G.Vec.xor(a, b), b), a,
    xor_eq0(G.Vec.xor(a, b), b),
    Equal.trans(G.Vec, x0(G.Vec.xor(a, b), b), x0(x0(a, b), b), a,
      Equal.cong(G.Vec, G.Vec, t => x0(t, b), G.Vec.xor(a, b), x0(a, b), xor_eq0(a, b)),
      xor_inv0(a, b)))

def xor_shape0(+a: G.Vec, +b: G.Vec) -> D.Same(x0(a, b), a):
  match a b:
    case G.VNil{} G.VNil{}:
      Unit{}
    case G.VNil{} G.VWord{y}:
      Unit{}
    case G.VNil{} G.VNode{bl, br}:
      Unit{}
    case G.VWord{x} G.VNil{}:
      Unit{}
    case G.VWord{x} G.VWord{y}:
      Unit{}
    case G.VWord{x} G.VNode{bl, br}:
      Unit{}
    case G.VNode{+al, +ar} G.VNil{}:
      same_refl(G.VNode{al, ar})
    case G.VNode{+al, +ar} G.VWord{y}:
      same_refl(G.VNode{al, ar})
    case G.VNode{al, ar} G.VNode{bl, br}:
      (xor_shape0(al, bl), xor_shape0(ar, br))

def Laws.xor_shape(a, b):
  %Equal.sym(G.Vec, G.Vec.xor(a, b), x0(a, b), xor_eq0(a, b)) : D.Same(_, a)
  xor_shape0(a, b)

# ---- G.Vec.muladd ---------------------------------------------------------

def Laws.muladd_zero(d, s):
  {==}

def Laws.muladd_one(d, s):
  {==}

def ma0(+c: U32, d: G.Vec, s: G.Vec) -> G.Vec:
  G.Vec.muladd.go(0n, c, d, s)

def ma_indep(+fk: Nat, +c: U32, +d: G.Vec, +s: G.Vec) -> {G.Vec.muladd.go(fk, c, d, s) == ma0(c, d, s) : G.Vec}:
  match fk:
    case 0n:
      {==}
    case 1n+q:
      match d s:
        case G.VNil{} G.VNil{}:
          {==}
        case G.VNil{} G.VWord{y}:
          {==}
        case G.VNil{} G.VNode{bl, br}:
          {==}
        case G.VWord{x} G.VNil{}:
          {==}
        case G.VWord{x} G.VWord{y}:
          {==}
        case G.VWord{x} G.VNode{bl, br}:
          {==}
        case G.VNode{al, ar} G.VNil{}:
          {==}
        case G.VNode{al, ar} G.VWord{y}:
          {==}
        case G.VNode{al, ar} G.VNode{bl, br}:
          vnode_cong(G.Vec.muladd.go(q, c, al, bl), G.Vec.muladd.go(q, c, ar, br), ma0(c, al, bl), ma0(c, ar, br), ma_indep(q, c, al, bl), ma_indep(q, c, ar, br))

def ma_invol0(+c: U32, +d: G.Vec, +s: G.Vec) -> {ma0(c, ma0(c, d, s), s) == d : G.Vec}:
  match d s:
    case G.VNil{} G.VNil{}:
      {==}
    case G.VNil{} G.VWord{y}:
      {==}
    case G.VNil{} G.VNode{bl, br}:
      {==}
    case G.VWord{x} G.VNil{}:
      {==}
    case G.VWord{x} G.VWord{y}:
      vword_cong(G.add(G.add(x, G.mulw(c, y)), G.mulw(c, y)), x, add_inv(x, G.mulw(c, y)))
    case G.VWord{x} G.VNode{bl, br}:
      {==}
    case G.VNode{al, ar} G.VNil{}:
      {==}
    case G.VNode{al, ar} G.VWord{y}:
      {==}
    case G.VNode{al, ar} G.VNode{bl, br}:
      vnode_cong(ma0(c, ma0(c, al, bl), bl), ma0(c, ma0(c, ar, br), br), al, ar, ma_invol0(c, al, bl), ma_invol0(c, ar, br))

def Laws.muladd_invol(c, d, s):
  Equal.trans(G.Vec, D.muladd_nz(c, D.muladd_nz(c, d, s), s), ma0(c, D.muladd_nz(c, d, s), s), d,
    ma_indep(G.Vec.fork_levels(D.muladd_nz(c, d, s)), c, D.muladd_nz(c, d, s), s),
    Equal.trans(G.Vec, ma0(c, D.muladd_nz(c, d, s), s), ma0(c, ma0(c, d, s), s), d,
      Equal.cong(G.Vec, G.Vec, t => ma0(c, t, s), D.muladd_nz(c, d, s), ma0(c, d, s), ma_indep(G.Vec.fork_levels(d), c, d, s)),
      ma_invol0(c, d, s)))

# ---- verify / solve_checked -------------------------------------------------

# a rewrite through BD refutes {False{} == True{}} in any goal
def BD(b: Bool, g: Type) -> Type:
  match b:
    case True{}:
      g
    case False{}:
      Unit

def absurd_ft(-g: Type, e: {False{} == True{} : Bool}) -> g:
  %e : BD(_, g)
  Unit{}

def and_elim(+x: Bool, +y: Bool, e: {Bool.and(x, y) == True{} : Bool}) -> {x == True{} : Bool} & {y == True{} : Bool}:
  match x:
    case False{}:
      absurd_ft({False{} == True{} : Bool} & {y == True{} : Bool}, e)
    case True{}:
      ({==}, e)

def cmp_ne(c: Cmp, e: {Cmp.is_eq(c) == True{} : Bool}) -> {c == EQ{} : Cmp}:
  match c:
    case LT{}:
      absurd_ft({LT{} == EQ{} : Cmp}, e)
    case EQ{}:
      {==}
    case GT{}:
      absurd_ft({GT{} == EQ{} : Cmp}, e)

def CD(c: Cmp, g: Type) -> Type:
  match c:
    case LT{}:
      Unit
    case EQ{}:
      g
    case GT{}:
      Unit

def absurd_lt(-g: Type, e: {LT{} == EQ{} : Cmp}) -> g:
  %e : CD(_, g)
  Unit{}

def absurd_gt(-g: Type, e: {GT{} == EQ{} : Cmp}) -> g:
  %e : CD(_, g)
  Unit{}

def bool_cmp_eq(+a: Bool, +b: Bool, e: {Bool.cmp(a, b) == EQ{} : Cmp}) -> {a == b : Bool}:
  match a b:
    case False{} False{}:
      {==}
    case False{} True{}:
      absurd_lt({False{} == True{} : Bool}, e)
    case True{} False{}:
      absurd_gt({True{} == False{} : Bool}, e)
    case True{} True{}:
      {==}

# Word.cmp.fin(ah, bh, t) is EQ only if ah == bh and t is EQ
def cmp_fin_eq(+ah: Bool, +bh: Bool, +t: Cmp, e: {Word.cmp.fin(ah, bh, t) == EQ{} : Cmp}) -> {ah == bh : Bool} & {t == EQ{} : Cmp}:
  match t:
    case LT{}:
      absurd_lt({ah == bh : Bool} & {LT{} == EQ{} : Cmp}, e)
    case EQ{}:
      (bool_cmp_eq(ah, bh, e), {==})
    case GT{}:
      absurd_gt({ah == bh : Bool} & {GT{} == EQ{} : Cmp}, e)

def word_cmp_eq.k(+p: Nat, +ah: Bool, +bh: Bool, +at: Word(p), +bt: Word(p), +t: Cmp, pr: {ah == bh : Bool} & {t == EQ{} : Cmp},
  rec: {t == EQ{} : Cmp} -> {at == bt : Word(p)}) -> {WCon{ah, at} == WCon{bh, bt} : Word(1n+p)}:
  (eh, et) = pr
  %eh : {WCon{ah, at} == WCon{_, bt} : Word(1n+p)}
  wcon_cong(p, ah, at, bt, rec(et))

def word_cmp_eq.fin(+p: Nat, +ah: Bool, +bh: Bool, +at: Word(p), +bt: Word(p), +t: Cmp, e: {Word.cmp.fin(ah, bh, t) == EQ{} : Cmp},
  rec: {t == EQ{} : Cmp} -> {at == bt : Word(p)}) -> {WCon{ah, at} == WCon{bh, bt} : Word(1n+p)}:
  word_cmp_eq.k(p, ah, bh, at, bt, t, cmp_fin_eq(ah, bh, t, e), rec)

def word_cmp_eq(+n: Nat, +a: Word(n), +b: Word(n), e: {Word.cmp(n, a, b) == EQ{} : Cmp}) -> {a == b : Word(n)}:
  match n:
    case 0n:
      match a b:
        case WNil{} WNil{}:
          {==}
    case 1n++p:
      match a b:
        case WCon{ah, at} WCon{bh, bt}:
          word_cmp_eq.fin(p, ah, bh, at, bt, Word.cmp(p, at, bt), e, t => word_cmp_eq(p, at, bt, t))

def u32_eq_sound(+a: U32, +b: U32, e: {U32.is_eq(a, b) == True{} : Bool}) -> {a == b : U32}:
  match a b:
    case U32{x} U32{y}:
      Equal.cong(Word(32n), U32, w => U32{w}, x, y, word_cmp_eq(32n, x, y, cmp_ne(Word.cmp(32n, x, y), e)))

def vec_eq_sound.k(+al: G.Vec, +ar: G.Vec, +bl: G.Vec, +br: G.Vec, pr: {V.Vec.eq(al, bl) == True{} : Bool} & {V.Vec.eq(ar, br) == True{} : Bool},
  rl: {V.Vec.eq(al, bl) == True{} : Bool} -> {al == bl : G.Vec}, rr: {V.Vec.eq(ar, br) == True{} : Bool} -> {ar == br : G.Vec}) -> {G.VNode{al, ar} == G.VNode{bl, br} : G.Vec}:
  (el, er) = pr
  vnode_cong(al, ar, bl, br, rl(el), rr(er))

def vec_eq_sound(+a: G.Vec, +b: G.Vec, e: {V.Vec.eq(a, b) == True{} : Bool}) -> {a == b : G.Vec}:
  match a b:
    case G.VNil{} G.VNil{}:
      {==}
    case G.VNil{} G.VWord{y}:
      absurd_ft({G.VNil{} == G.VWord{y} : G.Vec}, e)
    case G.VNil{} G.VNode{bl, br}:
      absurd_ft({G.VNil{} == G.VNode{bl, br} : G.Vec}, e)
    case G.VWord{x} G.VNil{}:
      absurd_ft({G.VWord{x} == G.VNil{} : G.Vec}, e)
    case G.VWord{x} G.VWord{y}:
      vword_cong(x, y, u32_eq_sound(x, y, e))
    case G.VWord{x} G.VNode{bl, br}:
      absurd_ft({G.VWord{x} == G.VNode{bl, br} : G.Vec}, e)
    case G.VNode{al, ar} G.VNil{}:
      absurd_ft({G.VNode{al, ar} == G.VNil{} : G.Vec}, e)
    case G.VNode{al, ar} G.VWord{y}:
      absurd_ft({G.VNode{al, ar} == G.VWord{y} : G.Vec}, e)
    case G.VNode{al, ar} G.VNode{bl, br}:
      vec_eq_sound.k(al, ar, bl, br, and_elim(V.Vec.eq(al, bl), V.Vec.eq(ar, br), e), t => vec_eq_sound(al, bl, t), t => vec_eq_sound(ar, br, t))


def verify_sound.k(+r: Y.Row, +rest: List<&2, Y.Row>, +sol: List<&2, G.Vec>,
  pr: {V.Row.holds(r, sol) == True{} : Bool} & {V.verify(rest, sol) == True{} : Bool},
  rec: {V.verify(rest, sol) == True{} : Bool} -> V.Sat(rest, sol)) -> V.Sat(r <> rest, sol):
  (h1, h2) = pr
  (vec_eq_sound(V.Row.eval(r, sol), V.Row.rhs(r), h1), rec(h2))

def Laws.verify_sound(rows, sol, e):
  match rows:
    case Nil{}:
      Unit{}
    case Con{r, rest}:
      verify_sound.k(r, rest, sol, and_elim(V.Row.holds(r, sol), V.verify(rest, sol), e), t => Laws.verify_sound(rest, sol, t))

# ---- solve_checked ----------------------------------------------------------

# a rewrite through DM refutes {None == Some{x}} in any goal
def DM(m: Maybe<&2, List<&2, G.Vec>>, g: Type) -> Type:
  match m:
    case None{}:
      Unit
    case Some{x}:
      g

def absurd_ns(-g: Type, -x: List<&2, G.Vec>, e: {None{} == Some{x} : Maybe<&2, List<&2, G.Vec>>}) -> g:
  %e : DM(_, g)
  Unit{}

def some_inj(+a: List<&2, G.Vec>, +b: List<&2, G.Vec>, e: {Some{a} == Some{b} : Maybe<&2, List<&2, G.Vec>>}) -> {a == b : List<&2, G.Vec>}:
  Equal.cong(Maybe<&2, List<&2, G.Vec>>, List<&2, G.Vec>, m => Maybe.default(&2, List<&2, G.Vec>, m, []), Some{a}, Some{b}, e)

# sc.pick(s, ok) == Some{sol} means ok held and s is sol
def pick_sound(+s: List<&2, G.Vec>, +ok: Bool, +sol: List<&2, G.Vec>, e: {V.sc.pick(s, ok) == Some{sol} : Maybe<&2, List<&2, G.Vec>>})
  -> {ok == True{} : Bool} & {s == sol : List<&2, G.Vec>}:
  match ok:
    case False{}:
      absurd_ns({False{} == True{} : Bool} & {s == sol : List<&2, G.Vec>}, sol, e)
    case True{}:
      ({==}, some_inj(s, sol, e))

def sc_sound.k(+rows: List<&2, Y.Row>, +s: List<&2, G.Vec>, +sol: List<&2, G.Vec>,
  pr: {V.verify(rows, s) == True{} : Bool} & {s == sol : List<&2, G.Vec>}) -> {V.verify(rows, sol) == True{} : Bool}:
  (hv, hs) = pr
  %hs : {V.verify(rows, _) == True{} : Bool}
  hv

def sc_sound(+m: Maybe<&2, List<&2, G.Vec>>, +rows: List<&2, Y.Row>, +sol: List<&2, G.Vec>, e: {V.sc.go(m, rows) == Some{sol} : Maybe<&2, List<&2, G.Vec>>}) -> {V.verify(rows, sol) == True{} : Bool}:
  match m:
    case None{}:
      absurd_ns({V.verify(rows, sol) == True{} : Bool}, sol, e)
    case Some{+s}:
      sc_sound.k(rows, s, sol, pick_sound(s, V.verify(rows, s), sol, e))

def Laws.solve_checked_sound(l, p, rows, sol, e):
  sc_sound(S.Solver.solve_p(l, p, rows), rows, sol, e)

# ---- Codec.split: exactly K symbols ------------------------------------------

def nat_add_zero(a: Nat) -> {Nat.add(a, 0n) == a : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      %nat_add_zero(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}
      {==}

def nat_add_succ(a: Nat, +b: Nat) -> {Nat.add(a, 1n+b) == 1n+Nat.add(a, b) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      %nat_add_succ(p, b) : {1n+Nat.add(p, 1n+b) == 1n+_ : Nat}
      {==}

# List.reverse.go keeps the length: |reverse.go(xs, acc)| = |xs| + |acc|
def rev_len(+xs: List<&2, G.Vec>, +acc: List<&2, G.Vec>) -> {List.length(&2, G.Vec, List.reverse.go(&2, G.Vec, xs, acc)) == Nat.add(List.length(&2, G.Vec, xs), List.length(&2, G.Vec, acc)) : Nat}:
  match xs:
    case Nil{}:
      {==}
    case Con{+h, +t}:
      Equal.trans(Nat, List.length(&2, G.Vec, List.reverse.go(&2, G.Vec, t, h <> acc)), Nat.add(List.length(&2, G.Vec, t), 1n+List.length(&2, G.Vec, acc)),
        1n+Nat.add(List.length(&2, G.Vec, t), List.length(&2, G.Vec, acc)),
        rev_len(t, h <> acc), nat_add_succ(List.length(&2, G.Vec, t), List.length(&2, G.Vec, acc)))

def ss_acc(s: Q.Ss) -> List<&2, G.Vec>:
  match s:
    case Q.Ss{xs, acc}:
      acc

def split_fin_len(w: Q.Wk, acc: List<&2, G.Vec>) -> {List.length(&2, G.Vec, ss_acc(Q.split.fin(w, acc))) == 1n+List.length(&2, G.Vec, acc) : Nat}:
  match w:
    case Q.Wk{r, rest, ws}:
      {==}

def split_next_len(+t: U32, +tw: Nat, +s: Q.Ss) -> {List.length(&2, G.Vec, ss_acc(Q.split.next(t, tw, s))) == 1n+List.length(&2, G.Vec, ss_acc(s)) : Nat}:
  match s:
    case Q.Ss{xs, acc}:
      split_fin_len(Q.sym.go(tw, Q.Wk{t, xs, Nil{}}), acc)

def split_go_len(+n: Nat, +t: U32, +tw: Nat, +s: Q.Ss) -> {List.length(&2, G.Vec, Q.split.go(n, t, tw, s)) == Nat.add(n, List.length(&2, G.Vec, ss_acc(s))) : Nat}:
  match n:
    case 0n:
      match s:
        case Q.Ss{+xs, +acc}:
          Equal.trans(Nat, List.length(&2, G.Vec, List.reverse.go(&2, G.Vec, acc, Nil{})), Nat.add(List.length(&2, G.Vec, acc), 0n), List.length(&2, G.Vec, acc),
            rev_len(acc, Nil{}), nat_add_zero(List.length(&2, G.Vec, acc)))
    case 1n++p:
      Equal.trans(Nat, List.length(&2, G.Vec, Q.split.go(p, t, tw, Q.split.next(t, tw, s))),
        Nat.add(p, List.length(&2, G.Vec, ss_acc(Q.split.next(t, tw, s)))), 1n+Nat.add(p, List.length(&2, G.Vec, ss_acc(s))),
        split_go_len(p, t, tw, Q.split.next(t, tw, s)),
        Equal.trans(Nat, Nat.add(p, List.length(&2, G.Vec, ss_acc(Q.split.next(t, tw, s)))), Nat.add(p, 1n+List.length(&2, G.Vec, ss_acc(s))), 1n+Nat.add(p, List.length(&2, G.Vec, ss_acc(s))),
          Equal.cong(Nat, Nat, x => Nat.add(p, x), List.length(&2, G.Vec, ss_acc(Q.split.next(t, tw, s))), 1n+List.length(&2, G.Vec, ss_acc(s)), split_next_len(t, tw, s)),
          nat_add_succ(p, List.length(&2, G.Vec, ss_acc(s)))))

def Laws.split_length(data, t):
  Equal.trans(Nat, List.length(&2, G.Vec, Q.split.go(U32.to_nat(Q.Codec.k_of(Q.len_u32(data, 0), t)), t, U32.to_nat(U32.shrn((t + 3 : U32), 2n)), Q.Ss{data, Nil{}})),
    Nat.add(U32.to_nat(Q.Codec.k_of(Q.len_u32(data, 0), t)), 0n), U32.to_nat(Q.Codec.k_of(Q.len_u32(data, 0), t)),
    split_go_len(U32.to_nat(Q.Codec.k_of(Q.len_u32(data, 0), t)), t, U32.to_nat(U32.shrn((t + 3 : U32), 2n)), Q.Ss{data, Nil{}}),
    nat_add_zero(U32.to_nat(Q.Codec.k_of(Q.len_u32(data, 0), t))))

# ---- octet addition / parameters ----------------------------------------------

def Laws.add_comm(a, b):
  G.add_comm(a, b)

def Laws.add_self(a):
  G.add_self(a)

def Laws.add_zero(a):
  G.add_zero(a)

def Laws.params_L(sp):
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      {==}

def Laws.params_P(sp):
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      {==}

def Laws.params_B(sp):
  match sp:
    case T.SP{kp, j, s, h, w, p1}:
      {==}
