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
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./constraints.bend as C
import ./solver.bend as S

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

# n encoding symbols for ESI esi0, esi0+1, ...
def symbols.go(n: Nat, +esi: U32, +enc: Enc, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      acc
    case 1n+p:
      symbols.go(p, (esi - 1 : U32), enc, Codec.symbol(enc, esi) <> acc)

def Codec.symbols(+enc: Enc, +esi0: U32, +n: U32) -> List<&2, G.Vec>:
  symbols.go(U32.to_nat(n), (esi0 + n - 1 : U32), enc, Nil{})

# ---------------------------------------------------------------------------
# Decoder
# ---------------------------------------------------------------------------

# source symbols ESI k-1 .. 0 re-encoded from the intermediate symbols (prepending => ascending)
def out.go(n: Nat, +i: U32, +sp: T.SP, +tr: C.ITree, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      acc
    case 1n+p:
      out.go(p, (i - 1 : U32), sp, tr, C.encode_idx(sp, tr, i) <> acc)

def dec.fin(r: Maybe<&2, List<&2, G.Vec>>, +k: U32, +sp: T.SP) -> Maybe<&2, List<&2, G.Vec>>:
  match r:
    case None{}:
      None{}
    case Some{inter}:
      Some{out.go(U32.to_nat(k), (k - 1 : U32), sp, C.index(inter), [])}

def dec.solve(m: Maybe<&2, T.SP>, enough: Bool, +k: U32, +t: U32, rv: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      None{}
    case Some{+sp}:
      match enough:
        case False{}:
          None{}
        case True{}:
          dec.fin(S.Solver.solve_p(R.L(sp), R.P(sp), append_rows(C.fixed(sp, t), C.received_rows(sp, k, rv))), k, sp)

# RFC 5.4: from >= K received symbols (ESI + data, any order) to the K source symbols.
# The decoding matrix (S+H constraint rows, one LT row per received symbol, the K'-K padding rows) is
# solved for the intermediate symbols and all K source symbols are re-encoded (for consistent input
# identical to the received source symbols).  None if fewer than K symbols are given, K is invalid, or
# T = 0, or the system is rank deficient (RFC 5.4.2 decoding failure).
def Codec.decode(+k: U32, +t: U32, received: List<&2, Y.Rcv>) -> Maybe<&2, List<&2, G.Vec>>:
  +rv = received
  dec.solve(R.params(k), band(U32.is_ge(len_rcv(rv, 0), k), band(U32.is_gt(k, 0), U32.is_gt(t, 0))), k, t, rv)
