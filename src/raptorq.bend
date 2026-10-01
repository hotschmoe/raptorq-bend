# End-to-end RaptorQ codec, RFC 6330 5.3 (encoding) and 5.4 (decoding), single source block.
# See docs/codec.md.  Composes tables/rfc_funcs, gf256, types, constraints and solver.
#
#   Codec.k_of(len, t)                 K = ceil(len / t)  (at least 1)
#   Codec.split(data, t)               bytes (U32 each < 256) -> K source symbols of T octets, zero padded
#   Codec.join(syms, t, len)           source symbols -> first `len` bytes
#   Codec.encoder(k, t, source)        Maybe<Enc>: runs the solver once, keeps the intermediate symbols
#   Codec.symbol(enc, esi) / repair    encoding symbol for ESI (ESI < K is the source symbol)
#   Codec.symbols(enc, esi0, n)        n consecutive encoding symbols
#   Codec.decode(k, t, received)       Maybe<List<Sym>>: the K source symbols
#   Codec.plan_for(k, esis)            Maybe<Plan>: the symbol-independent part of the solve for these received ESIs
#   Codec.encoder_plan(k)              plan_for(k, 0..k-1): the encoder's plan, reusable for every source block of this K
#   Codec.encode_with_plan(k, t, plan, source) / Codec.decode_with_plan(k, t, plan, syms)   (+ _auto IO variants)
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./constraints.bend as C
import ./solver.bend as S
import ./flat.bend as F

# ---------------------------------------------------------------------------
# Small tail-recursive list helpers (Base's List.length / List.append are not tail recursive and
# overflow the stack on >= ~32k elements).
# ---------------------------------------------------------------------------

def len_u32(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len_u32(t, (acc + 1 : U32))

def len_rcv(xs: List<&2, Y.Rcv>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len_rcv(t, (acc + 1 : U32))

def len_sym(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len_sym(t, (acc + 1 : U32))

def append_rows(xs: List<&2, Y.Row>, ys: List<&2, Y.Row>) -> List<&2, Y.Row>:
  List.reverse.go(&2, Y.Row, List.reverse(&2, Y.Row, xs), ys)

# ---------------------------------------------------------------------------
# Bytes <-> symbols.  A symbol of T octets is ceil(T/4) big-endian packed words, trailing octets zero.
# ---------------------------------------------------------------------------

type Nb is Data:
  Nb{b: U32, r: U32, rest: List<&2, U32>}

type Wd is Data:
  Wd{w: U32, r: U32, rest: List<&2, U32>}

type Sw is Data:
  Sw{ws: List<&2, U32>, rest: List<&2, U32>}

type Pb is Data:
  Pb{left: U32, acc: List<&2, U32>}

# next octet of the current symbol: r = octets of this symbol still to read (0 => padding)
def nb(+r: U32, xs: List<&2, U32>) -> Nb:
  match r:
    case 0:
      Nb{0, 0, xs}
    case _:
      match xs:
        case Nil{}:
          Nb{0, (r - 1 : U32), Nil{}}
        case Con{h, tl}:
          Nb{(h .&. 255 : U32), (r - 1 : U32), tl}

def word.d(+b0: U32, +b1: U32, +b2: U32, n: Nb) -> Wd:
  match n:
    case Nb{b3, r3, x3}:
      Wd{(b0 * 16777216 + b1 * 65536 + b2 * 256 + b3 : U32), r3, x3}

def word.c(+b0: U32, +b1: U32, n: Nb) -> Wd:
  match n:
    case Nb{b2, r2, x2}:
      word.d(b0, b1, b2, nb(r2, x2))

def word.b(+b0: U32, n: Nb) -> Wd:
  match n:
    case Nb{b1, r1, x1}:
      word.c(b0, b1, nb(r1, x1))

def word.a(n: Nb) -> Wd:
  match n:
    case Nb{b0, r0, x0}:
      word.b(b0, nb(r0, x0))

def word(+r: U32, xs: List<&2, U32>) -> Wd:
  word.a(nb(r, xs))

type Wk is Data:
  Wk{r: U32, rest: List<&2, U32>, ws: List<&2, U32>}

type Ss is Data:
  Ss{xs: List<&2, U32>, acc: List<&2, G.Vec>}

def wk.fin(w: Wd, ws: List<&2, U32>) -> Wk:
  match w:
    case Wd{w, r, rest}:
      Wk{r, rest, w <> ws}

def wk.step(st: Wk) -> Wk:
  match st:
    case Wk{r, rest, ws}:
      wk.fin(word(r, rest), ws)

# n words of one symbol (words accumulate in REVERSE in ws)
def sym.go(n: Nat, st: Wk) -> Wk:
  match n:
    case 0n:
      st
    case 1n+p:
      sym.go(p, wk.step(st))

def split.fin(w: Wk, acc: List<&2, G.Vec>) -> Ss:
  match w:
    case Wk{r, rest, ws}:
      Ss{rest, G.Vec.from_list(List.reverse(&2, U32, ws)) <> acc}

def split.next(+t: U32, +tw: Nat, st: Ss) -> Ss:
  match st:
    case Ss{xs, acc}:
      split.fin(sym.go(tw, Wk{t, xs, Nil{}}), acc)

def split.go(n: Nat, +t: U32, +tw: Nat, st: Ss) -> List<&2, G.Vec>:
  match n:
    case 0n:
      match st:
        case Ss{xs, acc}:
          List.reverse(&2, G.Vec, acc)
    case 1n+p:
      split.go(p, t, tw, split.next(t, tw, st))

# K = ceil(len / T), at least 1
def Codec.k_of(+len: U32, +t: U32) -> U32:
  U32.max(1, ((len + t - 1) / t : U32))

# RFC 4.4.1.2, single source block: K source symbols of T octets (last one zero padded).
def Codec.split(data: List<&2, U32>, +t: U32) -> List<&2, G.Vec>:
  +d = data
  +n = len_u32(d, 0)
  split.go(U32.to_nat(Codec.k_of(n, t)), t, U32.to_nat(U32.shrn((t + 3 : U32), 2n)), Ss{d, Nil{}})

def pushb(+b: U32, st: Pb) -> Pb:
  match st:
    case Pb{left, acc}:
      match left:
        case 0:
          Pb{0, acc}
        case _:
          Pb{(left - 1 : U32), b <> acc}

def push4(+w: U32, st: Pb) -> Pb:
  pushb((w .&. 255 : U32), pushb((U32.shrn(w, 8n) .&. 255 : U32), pushb((U32.shrn(w, 16n) .&. 255 : U32), pushb((U32.shrn(w, 24n) .&. 255 : U32), st))))

# push at most `left` octets of the words onto acc (reversed)
def wb.go(ws: List<&2, U32>, st: Pb) -> Pb:
  match ws:
    case Nil{}:
      st
    case Con{w, rest}:
      wb.go(rest, push4(w, st))

def wb.acc(st: Pb) -> List<&2, U32>:
  match st:
    case Pb{left, acc}:
      acc

def wb.run(ws: List<&2, U32>, +left: U32, acc: List<&2, U32>) -> List<&2, U32>:
  wb.acc(wb.go(ws, Pb{left, acc}))

# the T octets of a symbol
def Codec.sym_bytes(+v: G.Vec, +t: U32) -> List<&2, U32>:
  List.reverse(&2, U32, wb.run(G.Vec.to_list(v, Nil{}), t, Nil{}))

def join.go(syms: List<&2, G.Vec>, +t: U32, +rem: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match syms:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case Con{v, rest}:
      +lim = U32.min(t, rem)
      join.go(rest, t, (rem - lim : U32), wb.run(G.Vec.to_list(v, Nil{}), lim, acc))

# the first `len` octets of the concatenated source symbols
def Codec.join(syms: List<&2, G.Vec>, +t: U32, +len: U32) -> List<&2, U32>:
  join.go(syms, t, len, Nil{})

# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------

type Enc is Data:
  Enc{k: U32, t: U32, sp: T.SP, tr: C.ITree}

def enc.fin(r: Maybe<&2, List<&2, G.Vec>>, +k: U32, +t: U32, +sp: T.SP) -> Maybe<&2, Enc>:
  match r:
    case None{}:
      None{}
    case Some{inter}:
      Some{Enc{k, t, sp, C.index(inter)}}

def enc.solve(m: Maybe<&2, T.SP>, ok: Bool, +k: U32, +t: U32, source: List<&2, G.Vec>) -> Maybe<&2, Enc>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match ok:
        case False{}:
          None{}
        case True{}:
          enc.fin(S.Solver.solve_p(R.L(sp), R.P(sp), append_rows(C.fixed(sp, t), C.source_rows(sp, source))), k, t, sp)

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

# Runs the solver once (RFC 5.3.3.4): None if K = 0, T = 0, K is out of range (K <= 56403) or the
# number of source symbols is not K.
def Codec.encoder(+k: U32, +t: U32, source: List<&2, G.Vec>) -> Maybe<&2, Enc>:
  +src = source
  +ok = band(U32.is_eq(len_sym(src, 0), k), band(U32.is_gt(k, 0), U32.is_gt(t, 0)))
  enc.solve(R.params(k), ok, k, t, src)

# Encoding symbol for ESI (RFC 5.3.4): ESI < K is the source symbol (systematic), ESI >= K a repair
# symbol (ISI = ESI + K' - K).
def Codec.symbol(+enc: Enc, +esi: U32) -> G.Vec:
  match enc:
    case Enc{+k, t, +sp, tr}:
      C.encode_idx(sp, tr, C.isi_of(esi, k, R.Kp(sp)))

def Codec.repair(+enc: Enc, +esi: U32) -> G.Vec:
  Codec.symbol(enc, esi)

# n encoding symbols for ESI esi0, esi0+1, ... via the per-symbol tree path (cheap for a handful of symbols)
def symbols.go(n: Nat, +esi: U32, +enc: Enc, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      acc
    case 1n+p:
      symbols.go(p, (esi - 1 : U32), enc, Codec.symbol(enc, esi) <> acc)

# Many symbols: the L intermediate symbols are copied ONCE into one flat Array<U32> and every symbol is a tail loop over
# slices (src/flat.bend, docs/profile.md R1); few symbols: the tree walk (the copy costs about 40 tree-path symbols).
# Same symbols either way, bit for bit.
def symbols.pick(+big: Bool, +enc: Enc, +esi0: U32, +n: U32) -> List<&2, G.Vec>:
  match big:
    case True{}:
      match enc:
        case Enc{+k, t, +sp, +tr}:
          F.Flat.encode_tree(sp, k, tr, esi0, n)
    case False{}:
      symbols.go(U32.to_nat(n), (esi0 + n - 1 : U32), enc, Nil{})

def symbols.size(+enc: Enc) -> U32:
  match enc:
    case Enc{k, t, +sp, tr}:
      R.L(sp)

def Codec.symbols(+enc: Enc, +esi0: U32, +n: U32) -> List<&2, G.Vec>:
  symbols.pick(U32.is_ge((n * 40 : U32), symbols.size(enc)), enc, esi0, n)

# ---------------------------------------------------------------------------
# Decoder
# ---------------------------------------------------------------------------

# the K source symbols (ESI 0..K-1, ISI = ESI) are re-encoded from the intermediate symbols on a flat array (src/flat.bend)
def dec.fin(r: Maybe<&2, List<&2, G.Vec>>, +k: U32, +sp: T.SP) -> Maybe<&2, List<&2, G.Vec>>:
  match r:
    case None{}:
      None{}
    case Some{inter}:
      Some{F.Flat.encode_list(sp, k, inter, 0, k)}

# the K source symbols from a plan and the rhs symbols: replay on the arena, re-encode from it (no tree conversion in between)
def dec.arena(pl: Maybe<&2, S.Plan>, rhs: List<&2, G.Vec>, +k: U32, +sp: T.SP) -> Maybe<&2, List<&2, G.Vec>>:
  match pl:
    case None{}:
      None{}
    case Some{plan}:
      Some{F.Flat.encode_arena(sp, k, S.Solver.apply_arena(plan, rhs), 0, k)}

def dec.solve(m: Maybe<&2, T.SP>, enough: Bool, +k: U32, +t: U32, rv: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match enough:
        case False{}:
          None{}
        case True{}:
          +rows = append_rows(C.fixed(sp, t), C.received_rows(sp, k, rv))
          dec.arena(S.Solver.plan(R.L(sp), R.P(sp), rows), S.rows_rhs(rows, Nil{}), k, sp)

# RFC 5.4: from >= K received symbols (ESI + data, any order) to the K source symbols.
# The decoding matrix (S+H constraint rows, one LT row per received symbol, the K'-K padding rows) is
# solved for the intermediate symbols and all K source symbols are re-encoded (for consistent input
# identical to the received source symbols).  None if fewer than K symbols are given, K is invalid, or
# T = 0, or the system is rank deficient (RFC 5.4.2 decoding failure).
def Codec.decode(+k: U32, +t: U32, received: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  +rv = received
  dec.solve(R.params(k), band(U32.is_ge(len_rcv(rv, 0), k), band(U32.is_gt(k, 0), U32.is_gt(t, 0))), k, t, rv)

# ---------------------------------------------------------------------------
# Auto-parallel IO variants (docs/perf.md section 4): the same answers as Codec.encoder / Codec.decode (bit for
# bit), but the solve is Solver.solve_auto, which slices long symbols (>= 256 octets) over the available threads
# (IO.thread_count, i.e. `--threads N` of a native binary).  For short symbols they are the same as the pure ones.
# ---------------------------------------------------------------------------

def enc.solve_auto(m: Maybe<&2, T.SP>, ok: Bool, +k: U32, +t: U32, source: List<&2, G.Vec>) -> IO(Maybe<&2, Enc>):
  match m:
    case None{}:
      IO.pure(Maybe<&2, Enc>, None{})
    case Some{+sp}:
      match ok:
        case False{}:
          IO.pure(Maybe<&2, Enc>, None{})
        case True{}:
          do IO<Maybe<&2, Enc>>:
            r : Maybe<&2, List<&2, G.Vec>> <- S.Solver.solve_auto(R.L(sp), R.P(sp), append_rows(C.fixed(sp, t), C.source_rows(sp, source)))
            IO.pure(Maybe<&2, Enc>, enc.fin(r, k, t, sp))

def Codec.encoder_auto(+k: U32, +t: U32, source: List<&2, G.Vec>) -> IO(Maybe<&2, Enc>):
  +src = source
  +ok = band(U32.is_eq(len_sym(src, 0), k), band(U32.is_gt(k, 0), U32.is_gt(t, 0)))
  enc.solve_auto(R.params(k), ok, k, t, src)

def dec.solve_auto(m: Maybe<&2, T.SP>, enough: Bool, +k: U32, +t: U32, rv: List<&2, Y.Rcv>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  match m:
    case None{}:
      IO.pure(Maybe<&2, List<&2, G.Vec>>, None{})
    case Some{+sp}:
      match enough:
        case False{}:
          IO.pure(Maybe<&2, List<&2, G.Vec>>, None{})
        case True{}:
          do IO<Maybe<&2, List<&2, G.Vec>>>:
            r : Maybe<&2, List<&2, G.Vec>> <- S.Solver.solve_auto(R.L(sp), R.P(sp), append_rows(C.fixed(sp, t), C.received_rows(sp, k, rv)))
            IO.pure(Maybe<&2, List<&2, G.Vec>>, dec.fin(r, k, sp))

def Codec.decode_auto(+k: U32, +t: U32, received: List<&2, Y.Rcv>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  +rv = received
  dec.solve_auto(R.params(k), band(U32.is_ge(len_rcv(rv, 0), k), band(U32.is_gt(k, 0), U32.is_gt(t, 0))), k, t, rv)

# ---------------------------------------------------------------------------
# Plans (docs/plan_apply.md): RFC 5.4.2.2 separation of the symbol-independent part of the solve (pivot order,
# elimination log, dense tail solution) from the symbols.  The plan depends only on K and WHICH ESIs are received (in
# which order), not on T or the data: for the encoder (all K source symbols "received") it is computed once per K and reused
# for every source block / symbol size; for the decoder it is computed once per loss pattern.
# ---------------------------------------------------------------------------

def rcv_rev(es: List<&2, U32>, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match es:
    case Nil{}:
      acc
    case Con{e, tl}:
      rcv_rev(tl, Y.Rcv{e, G.VNil{}} <> acc)

def plan.go(m: Maybe<&2, T.SP>, ok: Bool, +k: U32, es: List<&2, U32>) -> Maybe<&2, S.Plan>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match ok:
        case False{}:
          None{}
        case True{}:
          S.Solver.plan(R.L(sp), R.P(sp), append_rows(C.fixed(sp, 0), C.received_rows(sp, k, rcv_rev(es, []))))

# The plan for a decoder that receives the symbols with these ESIs (in this order; K <= len(esis)).  The rows of the system
# are the S+H constraint rows, one row per received symbol (in the order given) and the K'-K padding rows.  None if
# fewer than K ESIs are given, K is invalid, or the system is rank deficient (RFC 5.4.2 decoding failure).
def Codec.plan_for(+k: U32, esis: List<&2, U32>) -> Maybe<&2, S.Plan>:
  +es = esis
  plan.go(R.params(k), band(U32.is_ge(len_u32(es, 0), k), U32.is_gt(k, 0)), k, es)

def esi_seq(n: Nat, +i: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      esi_seq(p, (i - 1 : U32), i <> acc)

# The encoder's plan: the systematic symbols ESI 0..K-1 "received" (RFC 5.3.3.4).  Reusable for every source block with this K
# and any T.
def Codec.encoder_plan(+k: U32) -> Maybe<&2, S.Plan>:
  Codec.plan_for(k, esi_seq(U32.to_nat(k), (k - 1 : U32), []))

def zeros_rep(n: Nat, +z: G.Vec, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      acc
    case 1n+p:
      zeros_rep(p, z, z <> acc)

def append_syms(xs: List<&2, G.Vec>, ys: List<&2, G.Vec>) -> List<&2, G.Vec>:
  List.reverse.go(&2, G.Vec, List.reverse(&2, G.Vec, xs), ys)

# rhs symbols of the plan's rows: S+H zero symbols, the received symbols, K'-K zero symbols
def wp.rhs(+sp: T.SP, +k: U32, +t: U32, syms: List<&2, G.Vec>) -> List<&2, G.Vec>:
  +z = C.zero(t)
  append_syms(zeros_rep(U32.to_nat((R.S(sp) + R.H(sp) : U32)), z, []), append_syms(syms, zeros_rep(U32.to_nat((R.Kp(sp) - k : U32)), z, [])))

# the plan must belong to this K (columns) and to as many rows as the symbols make
def wp.ok(+plan: S.Plan, +rhs: List<&2, G.Vec>, +l: U32) -> Bool:
  band(U32.is_eq(len_sym(rhs, 0), S.Solver.plan_rows(plan)), U32.is_eq(S.Solver.plan_cols(plan), l))

def wp.fin(ok: Bool, plan: S.Plan, rhs: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match ok:
    case True{}:
      Some{S.Solver.apply(plan, rhs)}
    case False{}:
      None{}

# the L intermediate symbols from a plan and the received symbols (same order as the ESIs given to plan_for)
def wp.inter(+sp: T.SP, +k: U32, +t: U32, +plan: S.Plan, syms: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  +rhs = wp.rhs(sp, k, t, syms)
  wp.fin(wp.ok(plan, rhs, R.L(sp)), plan, rhs)

def ewp.go(m: Maybe<&2, T.SP>, tok: Bool, +k: U32, +t: U32, plan: S.Plan, source: List<&2, G.Vec>) -> Maybe<&2, Enc>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match tok:
        case False{}:
          None{}
        case True{}:
          enc.fin(wp.inter(sp, k, t, plan, source), k, t, sp)

# Codec.encoder with a plan from Codec.encoder_plan(k): only the symbol side of the solve is run.  None if the plan does
# not fit (wrong K or rows), the number of source symbols is not K, or T = 0.  Bit for bit the same as Codec.encoder.
def Codec.encode_with_plan(+k: U32, +t: U32, plan: S.Plan, source: List<&2, G.Vec>) -> Maybe<&2, Enc>:
  +src = source
  ewp.go(R.params(k), band(U32.is_eq(len_sym(src, 0), k), U32.is_gt(t, 0)), k, t, plan, src)

def dwp.fin(ok: Bool, plan: S.Plan, rhs: List<&2, G.Vec>, +k: U32, +sp: T.SP) -> Maybe<&2, List<&2, G.Vec>>:
  match ok:
    case True{}:
      dec.arena(Some{plan}, rhs, k, sp)
    case False{}:
      None{}

def dwp.go(m: Maybe<&2, T.SP>, tok: Bool, +k: U32, +t: U32, +plan: S.Plan, syms: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match tok:
        case False{}:
          None{}
        case True{}:
          +rhs = wp.rhs(sp, k, t, syms)
          dwp.fin(wp.ok(plan, rhs, R.L(sp)), plan, rhs, k, sp)

# Codec.decode with a plan from Codec.plan_for(k, esis): `syms` are the received symbols' data in the SAME order as `esis`.
# Returns the K source symbols (re-encoded from the intermediate symbols, like Codec.decode).  None if the plan does not fit
# or T = 0.
def Codec.decode_with_plan(+k: U32, +t: U32, plan: S.Plan, syms: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  dwp.go(R.params(k), U32.is_gt(t, 0), k, t, plan, syms)

# ---- IO variants: Solver.apply_auto (symbol slicing over IO.thread_count for symbols >= 256 octets) ------------------
def wp.fin_auto(ok: Bool, plan: S.Plan, rhs: List<&2, G.Vec>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  match ok:
    case True{}:
      do IO<Maybe<&2, List<&2, G.Vec>>>:
        r : List<&2, G.Vec> <- S.Solver.apply_auto(plan, rhs)
        IO.pure(Maybe<&2, List<&2, G.Vec>>, Some{r})
    case False{}:
      IO.pure(Maybe<&2, List<&2, G.Vec>>, None{})

def wp.inter_auto(+sp: T.SP, +k: U32, +t: U32, +plan: S.Plan, syms: List<&2, G.Vec>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  +rhs = wp.rhs(sp, k, t, syms)
  wp.fin_auto(wp.ok(plan, rhs, R.L(sp)), plan, rhs)

def ewp.go_auto(m: Maybe<&2, T.SP>, tok: Bool, +k: U32, +t: U32, plan: S.Plan, source: List<&2, G.Vec>) -> IO(Maybe<&2, Enc>):
  match m:
    case None{}:
      IO.pure(Maybe<&2, Enc>, None{})
    case Some{+sp}:
      match tok:
        case False{}:
          IO.pure(Maybe<&2, Enc>, None{})
        case True{}:
          do IO<Maybe<&2, Enc>>:
            r : Maybe<&2, List<&2, G.Vec>> <- wp.inter_auto(sp, k, t, plan, source)
            IO.pure(Maybe<&2, Enc>, enc.fin(r, k, t, sp))

def Codec.encode_with_plan_auto(+k: U32, +t: U32, plan: S.Plan, source: List<&2, G.Vec>) -> IO(Maybe<&2, Enc>):
  +src = source
  ewp.go_auto(R.params(k), band(U32.is_eq(len_sym(src, 0), k), U32.is_gt(t, 0)), k, t, plan, src)

def dwp.go_auto(m: Maybe<&2, T.SP>, tok: Bool, +k: U32, +t: U32, plan: S.Plan, syms: List<&2, G.Vec>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  match m:
    case None{}:
      IO.pure(Maybe<&2, List<&2, G.Vec>>, None{})
    case Some{+sp}:
      match tok:
        case False{}:
          IO.pure(Maybe<&2, List<&2, G.Vec>>, None{})
        case True{}:
          do IO<Maybe<&2, List<&2, G.Vec>>>:
            r : Maybe<&2, List<&2, G.Vec>> <- wp.inter_auto(sp, k, t, plan, syms)
            IO.pure(Maybe<&2, List<&2, G.Vec>>, dec.fin(r, k, sp))

def Codec.decode_with_plan_auto(+k: U32, +t: U32, plan: S.Plan, syms: List<&2, G.Vec>) -> IO(Maybe<&2, List<&2, G.Vec>>):
  dwp.go_auto(R.params(k), U32.is_gt(t, 0), k, t, plan, syms)
