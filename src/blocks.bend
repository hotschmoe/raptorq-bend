# RFC 6330 multi-block objects (sections 3.3, 4.3, 4.4): object transmission information (OTI), the Partition[I,J]
# function, source-block / sub-block layout, and encoding / decoding of whole objects block by block.  See docs/multiblock.md.
#
#   Blocks.partition(i, j)            -> Part{il, ish, jl, js}                       RFC 4.4.1.2
#   Blocks.kl(ws, al, t, n)           -> K_L(n): largest Table 2 value K' <= WS / (Al * ceil(T / (Al * n)))   RFC 4.3
#   Blocks.params(f, p, al, ws, ss)   -> Maybe<Oti>: T, Z, N derived from F, P', Al, WS, SS                    RFC 4.3
#   Blocks.oti(f, t, z, n, al)        -> Maybe<Oti> (validated), Blocks.oti_bytes / oti_parse: the 12 octets of RFC 3.3.2 / 3.3.3
#   Blocks.layout(oti)                -> Lay{kt, kl, ks, zl, zs}; Blocks.block_k(lay, sbn) = K of source block sbn
#   Blocks.encode_object(w, oti, data)-> Maybe<Obj>   bytes -> source blocks -> one encoder per block, w = leaf tasks
#   Blocks.encode_syms(w, oti, src)   -> Maybe<Obj>   same from the source symbols of every block (List<List<Sym>>)
#   Blocks.symbol(obj, sbn, esi)      -> Maybe<Sym>   Blocks.repair(w, obj, n) -> n repair symbols of EVERY block (parallel)
#   Blocks.decode_object(w, oti, pkts)-> Maybe<bytes> pkts: List<Pkt{sbn, esi, sym}> in any order; Blocks.decode_syms -> source symbols
#
# Parallelism (docs/multiblock.md): blocks are independent.  Every parallel function is ONE divide-and-conquer over the block range
# [0, Z) with `w` leaf tasks (w = Z: every block its own task; w = 1: sequential): a node splits its blocks proportionally to the
# workers (w/2 : w - w/2), forks both halves and appends the result lists; a leaf runs its blocks in a plain tail-recursive loop.  The first fork is the only one reached
# from sequential code; all others happen inside running tasks.  The decoder also routes the received packets down the same
# tree (partition by SBN at every node), so no shared array or list is scanned per block.
# The plan (symbol-independent half of the solve) depends only on K (and the received ESIs), so it is computed ONCE per distinct
# K (all ZL blocks share K_L, all ZS blocks share K_S) and shared by every block with the same K (decoder: the same ESI sequence).
#
# Limits: F is a U32 (< 4 GiB, RFC: 40 bit), Z <= 255 (8 bit), N <= 65535, T <= 65535, Al <= 255, K <= 56403 per block.
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./solver.bend as S
import ./raptorq.bend as Q

# ---------------------------------------------------------------------------
# types
# ---------------------------------------------------------------------------

# FEC object transmission information (RFC 3.3.2, 3.3.3): transfer length F, symbol size T, source blocks Z, sub-blocks N, alignment Al
type Oti is Data:
  Oti{f: U32, t: U32, z: U32, n: U32, al: U32}

# Partition[I, J] = (IL, IS, JL, JS): JL blocks of IL = ceil(I/J), JS blocks of IS = floor(I/J);  (ish = IS)
type Part is Data:
  Part{il: U32, ish: U32, jl: U32, js: U32}

# Kt = ceil(F/T) source symbols in all, (KL, KS, ZL, ZS) = Partition[Kt, Z]: ZL blocks of KL symbols, then ZS of KS
type Lay is Data:
  Lay{kt: U32, kl: U32, ks: U32, zl: U32, zs: U32}

# a received / transmitted packet with one encoding symbol (RFC 4.4.2): source block number, ESI, symbol
type Pkt is Data:
  Pkt{sbn: U32, esi: U32, sym: G.Vec}

# ---------------------------------------------------------------------------
# Partition, K_L, parameters (RFC 4.3, 4.4.1.2)
# ---------------------------------------------------------------------------

def cdiv.fin(+q: U32, exact: Bool) -> U32:
  match exact:
    case True{}:
      q
    case False{}:
      (q + 1 : U32)

# ceil(a / b) without overflow (0 if b = 0)
def Blocks.cdiv(+a: U32, +b: U32) -> U32:
  cdiv.fin((a / b : U32), U32.is_eq((a % b : U32), 0))

def Blocks.partition(+i: U32, +j: U32) -> Part:
  +q = (i / j : U32)
  +jl = (i - q * j : U32)
  Part{Blocks.cdiv(i, j), q, jl, (j - jl : U32)}

def lay.go(+kt: U32, p: Part) -> Lay:
  match p:
    case Part{il, q, jl, js}:
      Lay{kt, il, q, jl, js}

def Blocks.layout(oti: Oti) -> Lay:
  match oti:
    case Oti{+f, +t, +z, n, al}:
      lay.go(Blocks.cdiv(f, t), Blocks.partition(Blocks.cdiv(f, t), z))

def Blocks.num_blocks(lay: Lay) -> U32:
  match lay:
    case Lay{kt, kl, ks, zl, zs}:
      (zl + zs : U32)

# K of source block sbn (0 beyond the last block)
def block_k.go(+sbn: U32, +kl: U32, +ks: U32, +zl: U32, +z: U32) -> U32:
  Bool.pick(U32, U32.is_lt(sbn, zl), kl, Bool.pick(U32, U32.is_lt(sbn, z), ks, 0))

def Blocks.block_k(lay: Lay, +sbn: U32) -> U32:
  match lay:
    case Lay{kt, +kl, +ks, +zl, +zs}:
      block_k.go(sbn, kl, ks, zl, (zl + zs : U32))

# largest Table 2 value K' <= x, scanning down from x (0 for x < 10); K' is in Table 2 iff the smallest K' >= x is x itself
def kmax.go(n: Nat, hit: Bool, +x: U32) -> U32:
  match n:
    case 0n:
      Bool.pick(U32, hit, x, 0)
    case 1n+p:
      match hit:
        case True{}:
          x
        case False{}:
          kmax.go(p, U32.is_eq(R.Kp(T.sp_row((x - 1 : U32))), (x - 1 : U32)), (x - 1 : U32))

def kmax.start(+x: U32) -> U32:
  Bool.pick(U32, U32.is_ge(x, 56403), 56403, Bool.pick(U32, U32.is_lt(x, 10), 0, kmax.go(4096n, U32.is_eq(R.Kp(T.sp_row(x)), x), x)))

# K_L(n) of RFC 4.3: the largest K' in Table 2 with K' <= WS / (Al * ceil(T / (Al * n)))  (0 if even K' = 10 does not fit)
def Blocks.kl(+ws: U32, +al: U32, +t: U32, +n: U32) -> U32:
  kmax.start((ws / (al * Blocks.cdiv(t, (al * n : U32)) : U32) : U32))

# smallest n' >= n (up to the fuel) with need <= K_L(n')
def nsel(fuel: Nat, hit: Bool, +n: U32, +need: U32, +ws: U32, +al: U32, +t: U32) -> U32:
  match fuel:
    case 0n:
      n
    case 1n+q:
      match hit:
        case True{}:
          n
        case False{}:
          nsel(q, U32.is_le(need, Blocks.kl(ws, al, t, (n + 1 : U32))), (n + 1 : U32), need, ws, al, t)

# Is (F, T, Z, N, Al) a valid OTI: T a positive multiple of Al, ceil(ceil(F/T)/Z) <= 56403 (RFC 4.4.1.2), every block and sub-block non-empty
def Blocks.valid(oti: Oti) -> Bool:
  match oti:
    case Oti{+f, +t, +z, +n, +al}:
      +kt = Blocks.cdiv(f, t)
      U32.is_gt(f, 0) && U32.is_gt(t, 0) && U32.is_le(t, 65535) && U32.is_gt(al, 0) && U32.is_le(al, 255) && U32.is_eq((t % al : U32), 0) && U32.is_ge(z, 1) && U32.is_le(z, 255) && U32.is_ge(n, 1) && U32.is_le(n, 65535) && U32.is_le(n, (t / al : U32)) && U32.is_ge(kt, z) && U32.is_le(Blocks.cdiv(kt, z), 56403)

def oti.go(ok: Bool, +o: Oti) -> Maybe<&2, Oti>:
  match ok:
    case True{}:
      Some{o}
    case False{}:
      None{}

def Blocks.oti(+f: U32, +t: U32, +z: U32, +n: U32, +al: U32) -> Maybe<&2, Oti>:
  oti.go(Blocks.valid(Oti{f, t, z, n, al}), Oti{f, t, z, n, al})

def Blocks.oti_n(oti: Oti) -> U32:
  match oti:
    case Oti{f, t, z, n, al}:
      n

def Blocks.oti_z(oti: Oti) -> U32:
  match oti:
    case Oti{f, t, z, n, al}:
      z

def Blocks.oti_t(oti: Oti) -> U32:
  match oti:
    case Oti{f, t, z, n, al}:
      t

def Blocks.oti_f(oti: Oti) -> U32:
  match oti:
    case Oti{f, t, z, n, al}:
      f

def params.go(ok: Bool, +f: U32, +t: U32, +al: U32, +ws: U32, +nmax: U32, +klmax: U32) -> Maybe<&2, Oti>:
  match ok:
    case False{}:
      None{}
    case True{}:
      +kt = Blocks.cdiv(f, t)
      +z = Blocks.cdiv(kt, klmax)
      +need = Blocks.cdiv(kt, z)
      Blocks.oti(f, t, z, nsel(U32.to_nat(nmax), U32.is_le(need, Blocks.kl(ws, al, t, 1)), 1, need, ws, al, t), al)

# RFC 4.3: T = P' (rounded down to a multiple of Al), Kt = ceil(F/T), N_max = floor(T / (SS * Al)), Z = ceil(Kt / K_L(N_max)), N = the
# smallest n <= N_max with ceil(Kt / Z) <= K_L(n).  WS = working memory in octets, SS = sub-symbol lower bound (in units of Al).
# None if the result is not a valid OTI (e.g. SS * Al > T, WS too small, F = 0).
def Blocks.params(+f: U32, +p: U32, +al: U32, +ws: U32, +ss: U32) -> Maybe<&2, Oti>:
  +t = (p - (p % al : U32) : U32)
  +nmax = (t / (ss * al : U32) : U32)
  +klmax = Blocks.kl(ws, al, t, nmax)
  params.go(U32.is_gt(nmax, 0) && U32.is_gt(klmax, 0), f, t, al, ws, nmax, klmax)

# ---------------------------------------------------------------------------
# OTI and payload id on the wire (RFC 3.2, 3.3.2, 3.3.3)
# ---------------------------------------------------------------------------

def byte(+x: U32, +sh: Nat) -> U32:
  (U32.shrn(x, sh) .&. 255 : U32)

# the 12 octets: F (40 bit), reserved, T (16), Z (8), N (16), Al (8)
def Blocks.oti_bytes(oti: Oti) -> List<&2, U32>:
  match oti:
    case Oti{+f, +t, +z, +n, +al}:
      0 <> byte(f, 24n) <> byte(f, 16n) <> byte(f, 8n) <> byte(f, 0n) <> 0 <> byte(t, 8n) <> byte(t, 0n) <> byte(z, 0n) <> byte(n, 8n) <> byte(n, 0n) <> byte(al, 0n) <> Nil{}

def oti_parse.go(ok: Bool, +o: Oti) -> Maybe<&2, Oti>:
  match ok:
    case True{}:
      oti.go(Blocks.valid(o), o)
    case False{}:
      None{}

# parse 12 octets; None unless exactly 12 octets < 256 with F < 2^32 (the top octet of the 40-bit F is 0) and a valid OTI
def Blocks.oti_parse(bs: List<&2, U32>) -> Maybe<&2, Oti>:
  match bs:
    case b0 <> b1 <> b2 <> b3 <> b4 <> r <> t0 <> t1 <> z <> n0 <> n1 <> a <> Nil{}:
      oti_parse.go(U32.is_eq(b0, 0), Oti{(U32.shln(b1, 24n) + U32.shln(b2, 16n) + U32.shln(b3, 8n) + b4 : U32), (U32.shln(t0, 8n) + t1 : U32), z, (U32.shln(n0, 8n) + n1 : U32), a})
    case _:
      None{}

# the 4-octet payload id: SBN (8 bit), ESI (24 bit)
def Blocks.payload_id(+sbn: U32, +esi: U32) -> U32:
  (U32.shln((sbn .&. 255 : U32), 24n) .|. (esi .&. 16777215 : U32) : U32)

# ---------------------------------------------------------------------------
# list helpers (tail recursive: objects are long)
# ---------------------------------------------------------------------------

def Blocks.app(-A: Data, xs: List<&2, A>, ys: List<&2, A>) -> List<&2, A>:
  List.reverse.go(&2, A, List.reverse(&2, A, xs), ys)

# (reversed prefix, rest) of a list
type Sp is Data:
  Sp{a: List<&2, U32>, b: List<&2, U32>}

def Sp.a(s: Sp) -> List<&2, U32>:
  match s:
    case Sp{a, b}:
      a

def Sp.b(s: Sp) -> List<&2, U32>:
  match s:
    case Sp{a, b}:
      b

# first n elements (reversed) and the rest; a short list gives a short prefix
def sp.go(n: Nat, xs: List<&2, U32>, acc: List<&2, U32>) -> Sp:
  match n:
    case 0n:
      Sp{acc, xs}
    case 1n+p:
      match xs:
        case Nil{}:
          Sp{acc, Nil{}}
        case Con{h, tl}:
          sp.go(p, tl, h <> acc)

# like sp.go, but a short list is padded with zero octets to n elements
def tp.go(n: Nat, xs: List<&2, U32>, acc: List<&2, U32>) -> Sp:
  match n:
    case 0n:
      Sp{acc, xs}
    case 1n+p:
      match xs:
        case Nil{}:
          tp.go(p, Nil{}, 0 <> acc)
        case Con{h, tl}:
          tp.go(p, tl, h <> acc)

def flat.go(xss: List<&2, List<&2, U32>>, acc: List<&2, U32>) -> List<&2, U32>:
  match xss:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case Con{xs, rest}:
      flat.go(rest, List.reverse.go(&2, U32, xs, acc))

# concatenation of a list of lists
def Blocks.flat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  flat.go(xss, Nil{})

# ---------------------------------------------------------------------------
# sub-blocks (RFC 4.4.1.2, last paragraphs): a source block of K symbols is cut into N contiguous sub-blocks, the first NL with
# K sub-symbols of TL*Al octets, the others of TS*Al octets; symbol m is the concatenation of the m-th sub-symbol of every sub-block.
# `interleave` maps the K*T octets of a source block (sub-block order) to its K symbols' octets (symbol order), `deinterleave` back.
# ---------------------------------------------------------------------------

# K pieces of w octets
def cut.go(n: Nat, +w: U32, xs: List<&2, U32>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      List.reverse(&2, List<&2, U32>, acc)
    case 1n+p:
      +st = sp.go(U32.to_nat(w), xs, Nil{})
      cut.go(p, w, Sp.b(st), List.reverse(&2, U32, Sp.a(st)) <> acc)

# rows[i] ++ pieces[i]
def zapp.go(rs: List<&2, List<&2, U32>>, ps: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match rs ps:
    case r <> rt p <> pt:
      zapp.go(rt, pt, Blocks.app(U32, r, p) <> acc)
    case _ _:
      List.reverse(&2, List<&2, U32>, acc)

def empty_rows(n: Nat, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      acc
    case 1n+p:
      empty_rows(p, Nil{} <> acc)

# octets of sub-block j (0 <= j < N): TL*Al for j < NL else TS*Al
def sub_w.go(+j: U32, +tl: U32, +ts: U32, +nl: U32, +al: U32) -> U32:
  (Bool.pick(U32, U32.is_lt(j, nl), tl, ts) * al : U32)

def sub_w.p(+j: U32, +al: U32, p: Part) -> U32:
  match p:
    case Part{tl, ts, nl, ns}:
      sub_w.go(j, tl, ts, nl, al)

def Blocks.sub_w(+oti: Oti, +j: U32) -> U32:
  match oti:
    case Oti{f, +t, z, +n, +al}:
      sub_w.p(j, al, Blocks.partition((t / al : U32), n))

def il.go(n: Nat, +j: U32, +k: U32, +oti: Oti, xs: List<&2, U32>, rows: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      rows
    case 1n+p:
      +w = Blocks.sub_w(oti, j)
      +st = sp.go(U32.to_nat((k * w : U32)), xs, Nil{})
      il.go(p, (j + 1 : U32), k, oti, Sp.b(st), zapp.go(rows, cut.go(U32.to_nat(k), w, List.reverse(&2, U32, Sp.a(st)), Nil{}), Nil{}))

# source block octets (sub-block order) -> symbol octets (K rows of T)
def Blocks.interleave(+oti: Oti, +k: U32, xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  il.go(U32.to_nat(Blocks.oti_n(oti)), 0, k, oti, xs, empty_rows(U32.to_nat(k), Nil{}))

# one pass of deinterleave: take w octets off every row
type Hs is Data:
  Hs{out: List<&2, U32>, rows: List<&2, List<&2, U32>>}

def Hs.out(h: Hs) -> List<&2, U32>:
  match h:
    case Hs{out, rows}:
      out

def Hs.rows(h: Hs) -> List<&2, List<&2, U32>>:
  match h:
    case Hs{out, rows}:
      rows

# out: reversed concatenation of the heads; rows: reversed remaining rows
def heads.go(+w: U32, rs: List<&2, List<&2, U32>>, +st: Hs) -> Hs:
  match rs:
    case Nil{}:
      st
    case Con{r, rest}:
      +sr = sp.go(U32.to_nat(w), r, Nil{})
      heads.go(w, rest, Hs{Blocks.app(U32, Sp.a(sr), Hs.out(st)), Sp.b(sr) <> Hs.rows(st)})

def dl.go(n: Nat, +j: U32, +oti: Oti, rows: List<&2, List<&2, U32>>, out: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      List.reverse(&2, U32, out)
    case 1n+p:
      +st = heads.go(Blocks.sub_w(oti, j), rows, Hs{out, Nil{}})
      dl.go(p, (j + 1 : U32), oti, List.reverse(&2, List<&2, U32>, Hs.rows(st)), Hs.out(st))

# symbol octets (K rows of T) -> source block octets (sub-block order)
def Blocks.deinterleave(+oti: Oti, rows: List<&2, List<&2, U32>>) -> List<&2, U32>:
  dl.go(U32.to_nat(Blocks.oti_n(oti)), 0, oti, rows, Nil{})

# ---------------------------------------------------------------------------
# source blocks <-> bytes
# ---------------------------------------------------------------------------

# the K*T octets of a block laid out symbol by symbol
def Blocks.pick_layout(single: Bool, +oti: Oti, +k: U32, bytes: List<&2, U32>) -> List<&2, U32>:
  match single:
    case True{}:
      bytes
    case False{}:
      Blocks.flat(Blocks.interleave(oti, k, bytes))

def blk_syms(+oti: Oti, +k: U32, bytes: List<&2, U32>) -> List<&2, G.Vec>:
  match oti:
    case Oti{f, +t, z, +n, al}:
      Q.Codec.split(Blocks.pick_layout(U32.is_eq(n, 1), oti, k, bytes), t)

def sb.go(n: Nat, +sbn: U32, +lay: Lay, +oti: Oti, data: List<&2, U32>, acc: List<&2, List<&2, G.Vec>>) -> List<&2, List<&2, G.Vec>>:
  match n:
    case 0n:
      List.reverse(&2, List<&2, G.Vec>, acc)
    case 1n+p:
      +k = Blocks.block_k(lay, sbn)
      +st = tp.go(U32.to_nat((k * Blocks.oti_t(oti) : U32)), data, Nil{})
      sb.go(p, (sbn + 1 : U32), lay, oti, Sp.b(st), blk_syms(oti, k, List.reverse(&2, U32, Sp.a(st))) <> acc)

def split_obj.go(ok: Bool, +oti: Oti, data: List<&2, U32>) -> List<&2, List<&2, G.Vec>>:
  match ok:
    case False{}:
      Nil{}
    case True{}:
      +lay = Blocks.layout(oti)
      sb.go(U32.to_nat(Blocks.num_blocks(lay)), 0, lay, oti, data, Nil{})

# the source symbols of every source block of an object (RFC 4.4.1.2: Z blocks of KL / KS symbols, the last symbol zero padded).
# Empty list for an invalid OTI.
def Blocks.split_object(+oti: Oti, data: List<&2, U32>) -> List<&2, List<&2, G.Vec>>:
  split_obj.go(Blocks.valid(oti), oti, data)

# the octets of one decoded block (K symbols), source order
def sym_rows(syms: List<&2, G.Vec>, +t: U32, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match syms:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, acc)
    case Con{v, rest}:
      sym_rows(rest, t, Q.Codec.sym_bytes(v, t) <> acc)

def blk_bytes.go(single: Bool, +oti: Oti, +k: U32, +t: U32, syms: List<&2, G.Vec>) -> List<&2, U32>:
  match single:
    case True{}:
      Q.Codec.join(syms, t, (k * t : U32))
    case False{}:
      Blocks.deinterleave(oti, sym_rows(syms, t, Nil{}))

def blk_bytes(+oti: Oti, +k: U32, syms: List<&2, G.Vec>) -> List<&2, U32>:
  match oti:
    case Oti{f, +t, z, +n, al}:
      blk_bytes.go(U32.is_eq(n, 1), oti, k, t, syms)

def jb.go(blocks: List<&2, List<&2, G.Vec>>, +sbn: U32, +lay: Lay, +oti: Oti, acc: List<&2, U32>) -> List<&2, U32>:
  match blocks:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case Con{b, rest}:
      jb.go(rest, (sbn + 1 : U32), lay, oti, List.reverse.go(&2, U32, blk_bytes(oti, Blocks.block_k(lay, sbn), b), acc))

# the F octets of the object from its decoded source blocks
def Blocks.join_object(+oti: Oti, blocks: List<&2, List<&2, G.Vec>>) -> List<&2, U32>:
  +all = jb.go(blocks, 0, Blocks.layout(oti), oti, Nil{})
  List.reverse(&2, U32, Sp.a(sp.go(U32.to_nat(Blocks.oti_f(oti)), all, Nil{})))

# ---------------------------------------------------------------------------
# parallel region tree
# ---------------------------------------------------------------------------

# fork levels needed for w workers
def levels(+w: U32) -> Nat:
  (U32.log2(U32.max(w, 1)) + 2n : Nat)

# a node with w workers and n blocks is a leaf if one worker is left or at most one block
def is_leaf(+w: U32, +n: U32) -> Bool:
  U32.is_le(w, 1) || U32.is_le(n, 1)

# the blocks of the left child: n * floor(w/2) / w  (proportional to its workers)
def n_left(+w: U32, +n: U32) -> U32:
  ((n * (w / 2 : U32) : U32) / w : U32)

# ---- plans (one per distinct K) ------------------------------------------------------------------------------------------

def k_if(+z: U32, +k: U32) -> U32:
  Bool.pick(U32, U32.is_gt(z, 0), k, 0)

# encoder plans (systematic symbols "received", RFC 5.3.3.4) for K_L and K_S; K = 0 (-> None) where the class is empty
type Pp is Data:
  Pp{pl: Maybe<&2, S.Plan>, ps: Maybe<&2, S.Plan>}

# both plans, computed concurrently (the only fork reached from sequential code before the block tree)
def Blocks.enc_plans(+kl: U32, +ks: U32, +zl: U32, +zs: U32) -> Pp:
  a b = Q.Codec.encoder_plan(k_if(zl, kl)) Q.Codec.encoder_plan(k_if(zs, ks))
  Pp{a, b}

def pp_pick(pp: Pp, sel: Bool) -> Maybe<&2, S.Plan>:
  match pp:
    case Pp{pl, ps}:
      match sel:
        case True{}:
          pl
        case False{}:
          ps

# (ESIs, symbols) of one block's packets, in arrival order
type Eb is Data:
  Eb{es: List<&2, U32>, ss: List<&2, G.Vec>}

def Eb.es(e: Eb) -> List<&2, U32>:
  match e:
    case Eb{es, ss}:
      es

def Eb.ss(e: Eb) -> List<&2, G.Vec>:
  match e:
    case Eb{es, ss}:
      ss

def eb_pick(hit: Bool, +esi: U32, v: G.Vec, +st: Eb) -> Eb:
  match hit:
    case True{}:
      Eb{esi <> Eb.es(st), v <> Eb.ss(st)}
    case False{}:
      st

# reversed lists of the packets of block sbn
def eb.go(pk: List<&2, Pkt>, +sbn: U32, st: Eb) -> Eb:
  match pk:
    case Nil{}:
      st
    case Con{p, rest}:
      match p:
        case Pkt{+s, +esi, v}:
          eb.go(rest, sbn, eb_pick(U32.is_eq(s, sbn), esi, v, st))

def eb.rev(+st: Eb) -> Eb:
  Eb{List.reverse(&2, U32, Eb.es(st)), List.reverse(&2, G.Vec, Eb.ss(st))}

def Blocks.eb_of(pk: List<&2, Pkt>, +sbn: U32) -> Eb:
  eb.rev(eb.go(pk, sbn, Eb{Nil{}, Nil{}}))

# the decoder plans of the first block of each K class, and the ESIs they were made for
type Dp is Data:
  Dp{esl: List<&2, U32>, pl: Maybe<&2, S.Plan>, ess: List<&2, U32>, ps: Maybe<&2, S.Plan>}

def dp.fin(+kl: U32, +ks: U32, el: Eb, eso: Eb) -> Dp:
  +esl = Eb.es(el)
  +ess = Eb.es(eso)
  a b = Q.Codec.plan_for(kl, esl) Q.Codec.plan_for(ks, ess)
  Dp{esl, a, ess, b}

# plans for the representative blocks (SBN 0 and SBN ZL), concurrently
def Blocks.dec_plans(+kl: U32, +ks: U32, +zl: U32, +zs: U32, pk: List<&2, Pkt>) -> Dp:
  +p = pk
  dp.fin(k_if(zl, kl), k_if(zs, ks), Blocks.eb_of(p, 0), Blocks.eb_of(p, zl))

def es_eq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      U32.is_eq(x, y) && es_eq(xs, ys)
    case _ _:
      False{}

# ---- one block ------------------------------------------------------------------------------------------------------------

def enc_run(mp: Maybe<&2, S.Plan>, +k: U32, +t: U32, src: List<&2, G.Vec>) -> Maybe<&2, Q.Enc>:
  match mp:
    case None{}:
      None{}
    case Some{plan}:
      Q.Codec.encode_with_plan(k, t, plan, src)

# encode + repair symbols without ever building the intermediate symbols as trees: the linear flat encoder (`Codec.encode_with_plan_flat`
# keeps the solved arena, `Codec.symbols_flat` generates from it, `Codec.out_vecs` reads the n symbols out); d = 0: one block = one worker
def er_gen(g: Q.GenF, +n: U32) -> Maybe<&2, List<&2, G.Vec>>:
  match g:
    case Q.GenF{e, out}:
      Some{Q.Codec.out_vecs(n, out)}

def er_enc(m: Q.MbF, +k: U32, +n: U32) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case Q.NoF{}:
      None{}
    case Q.SomeF{e}:
      er_gen(Q.Codec.symbols_flat(e, k, n), n)

def er_run(mp: Maybe<&2, S.Plan>, +k: U32, +t: U32, +n: U32, src: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match mp:
    case None{}:
      None{}
    case Some{plan}:
      er_enc(Q.Codec.encode_with_plan_flat(0, k, t, plan, src), k, n)

def rep_one(+e: Q.Enc, +n: U32) -> List<&2, G.Vec>:
  match e:
    case Q.Enc{+k, t, +sp, tr}:
      Q.Codec.symbols(e, k, n)

# the plan for a decoded block: the representative's if the same ESIs arrived in the same order, else its own
def dec_plan(same: Bool, +k: U32, es: List<&2, U32>, mp: Maybe<&2, S.Plan>) -> Maybe<&2, S.Plan>:
  match same:
    case True{}:
      mp
    case False{}:
      Q.Codec.plan_for(k, es)

def dec_run(mp: Maybe<&2, S.Plan>, +k: U32, +t: U32, ss: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match mp:
    case None{}:
      None{}
    case Some{plan}:
      Q.Codec.decode_with_plan(k, t, plan, ss)

def dec_blk(+sel: Bool, +k: U32, +t: U32, +dp: Dp, +eb: Eb) -> Maybe<&2, List<&2, G.Vec>>:
  match dp:
    case Dp{esl, pl, ess, ps}:
      +es = Eb.es(eb)
      dec_run(dec_plan(es_eq(es, Bool.pick(List<&2, U32>, sel, esl, ess)), k, es, Bool.pick(Maybe<&2, S.Plan>, sel, pl, ps)), k, t, Eb.ss(eb))

# ---- inputs and results of a node's block range ----------------------------------------------------------------------------

# the per-block inputs of a node's range: source symbols per block / encoders per block (first = first block of the range), or the
# received packets (of at least the blocks of the range)
type Pl is Data:
  PSrc{src: List<&2, List<&2, G.Vec>>}
  PEnc{encs: List<&2, Q.Enc>}
  PPkt{pk: List<&2, Pkt>}

type Pl2 is Data:
  Pl2{a: Pl, b: Pl}

def Pl2.a(x: Pl2) -> Pl:
  match x:
    case Pl2{a, b}:
      a

def Pl2.b(x: Pl2) -> Pl:
  match x:
    case Pl2{a, b}:
      b

# one block's result
type Rs is Data:
  RNo{}
  REnc{e: Q.Enc}
  RSy{s: List<&2, G.Vec>}

# what a region computes: mode 0 encode, 1 repair symbols from encoders, 2 decode, 3 encode + repair (fused, arena); n = repair
# symbols per block
type Cx is Data:
  Cx{mode: U32, t: U32, zl: U32, kl: U32, ks: U32, n: U32, pp: Pp, dp: Dp}

# packets with sbn < m (first) and >= m (second), arrival order kept
type Two is Data:
  Two{a: List<&2, Pkt>, b: List<&2, Pkt>}

def Two.a(x: Two) -> List<&2, Pkt>:
  match x:
    case Two{a, b}:
      a

def Two.b(x: Two) -> List<&2, Pkt>:
  match x:
    case Two{a, b}:
      b

def two_pick(lo: Bool, p: Pkt, +st: Two) -> Two:
  match lo:
    case True{}:
      Two{p <> Two.a(st), Two.b(st)}
    case False{}:
      Two{Two.a(st), p <> Two.b(st)}

def two.go(pk: List<&2, Pkt>, +m: U32, st: Two) -> Two:
  match pk:
    case Nil{}:
      st
    case Con{p, rest}:
      match p:
        case Pkt{+s, esi, v}:
          two.go(rest, m, two_pick(U32.is_lt(s, m), Pkt{s, esi, v}, st))

def two_rev(+x: Two) -> Two:
  Two{List.reverse(&2, Pkt, Two.a(x)), List.reverse(&2, Pkt, Two.b(x))}

def pl_two(t: Two) -> Pl2:
  match t:
    case Two{a, b}:
      Pl2{PPkt{a}, PPkt{b}}

# the inputs of the left child (first nl blocks) and the right child; nl blocks are dropped from the block lists, the packets are
# partitioned by SBN < m
def pl_split(pl: Pl, +nl: U32, +m: U32) -> Pl2:
  match pl:
    case PSrc{+src}:
      Pl2{PSrc{src}, PSrc{List.drop(&2, List<&2, G.Vec>, src, U32.to_nat(nl))}}
    case PEnc{+encs}:
      Pl2{PEnc{encs}, PEnc{List.drop(&2, Q.Enc, encs, U32.to_nat(nl))}}
    case PPkt{pk}:
      pl_two(two_rev(two.go(pk, m, Two{Nil{}, Nil{}})))

def pl_next(pl: Pl) -> Pl:
  match pl:
    case PSrc{src}:
      match src:
        case Nil{}:
          PSrc{Nil{}}
        case Con{b, rest}:
          PSrc{rest}
    case PEnc{encs}:
      match encs:
        case Nil{}:
          PEnc{Nil{}}
        case Con{e, rest}:
          PEnc{rest}
    case PPkt{pk}:
      PPkt{pk}

def rs_enc(m: Maybe<&2, Q.Enc>) -> Rs:
  match m:
    case None{}:
      RNo{}
    case Some{e}:
      REnc{e}

def rs_syms(m: Maybe<&2, List<&2, G.Vec>>) -> Rs:
  match m:
    case None{}:
      RNo{}
    case Some{s}:
      RSy{s}

def blk_src.go(fused: Bool, mp: Maybe<&2, S.Plan>, +k: U32, +t: U32, +n: U32, b: List<&2, G.Vec>) -> Rs:
  match fused:
    case True{}:
      rs_syms(er_run(mp, k, t, n, b))
    case False{}:
      rs_enc(enc_run(mp, k, t, b))

def blk_src(pl: Pl, +c: Bool, +k: U32, +t: U32, +n: U32, +fused: Bool, +pp: Pp) -> Rs:
  match pl:
    case PSrc{src}:
      match src:
        case Nil{}:
          RNo{}
        case Con{b, rest}:
          blk_src.go(fused, pp_pick(pp, c), k, t, n, b)
    case _:
      RNo{}

def blk_rep(pl: Pl, +n: U32) -> Rs:
  match pl:
    case PEnc{encs}:
      match encs:
        case Nil{}:
          RNo{}
        case Con{e, rest}:
          RSy{rep_one(e, n)}
    case _:
      RNo{}

def blk_dec(pl: Pl, +c: Bool, +k: U32, +t: U32, +sbn: U32, +dp: Dp) -> Rs:
  match pl:
    case PPkt{pk}:
      rs_syms(dec_blk(c, k, t, dp, Blocks.eb_of(pk, sbn)))
    case _:
      RNo{}

def blk.go(mode: U32, pl: Pl, +c: Bool, +k: U32, +t: U32, +n: U32, +sbn: U32, +pp: Pp, +dp: Dp) -> Rs:
  match mode:
    case 0:
      blk_src(pl, c, k, t, n, False{}, pp)
    case 1:
      blk_rep(pl, n)
    case 2:
      blk_dec(pl, c, k, t, sbn, dp)
    case _:
      blk_src(pl, c, k, t, n, True{}, pp)

def blk(+cx: Cx, +sbn: U32, pl: Pl) -> Rs:
  match cx:
    case Cx{mode, +t, +zl, +kl, +ks, +n, pp, dp}:
      +c = U32.is_lt(sbn, zl)
      blk.go(mode, pl, c, Bool.pick(U32, c, kl, ks), t, n, sbn, pp, dp)

# leaf: n blocks from sbn on, one worker, a tail-recursive loop
def leaf(n: Nat, +sbn: U32, +cx: Cx, +pl: Pl, acc: List<&2, Rs>) -> List<&2, Rs>:
  match n:
    case 0n:
      List.reverse(&2, Rs, acc)
    case 1n+p:
      leaf(p, (sbn + 1 : U32), cx, pl_next(pl), blk(cx, sbn, pl) <> acc)

# the divide-and-conquer over the block range [sbn, sbn + n) for w workers (d = fuel for the recursion)
def range(+d: Nat, lf: Bool, +w: U32, +n: U32, +sbn: U32, +cx: Cx, +pl: Pl) -> List<&2, Rs>:
  match d:
    case 0n:
      leaf(U32.to_nat(n), sbn, cx, pl, Nil{})
    case 1n+q:
      match lf:
        case True{}:
          leaf(U32.to_nat(n), sbn, cx, pl, Nil{})
        case False{}:
          +wl = (w / 2 : U32)
          +nl = n_left(w, n)
          +wr = (w - wl : U32)
          +nr = (n - nl : U32)
          +s2 = pl_split(pl, nl, (sbn + nl : U32))
          a b = range(q, is_leaf(wl, nl), wl, nl, sbn, cx, Pl2.a(s2)) range(q, is_leaf(wr, nr), wr, nr, (sbn + nl : U32), cx, Pl2.b(s2))
          Blocks.app(Rs, a, b)

def run(+w: U32, +z: U32, +cx: Cx, pl: Pl) -> List<&2, Rs>:
  range(levels(w), is_leaf(w, z), w, z, 0, cx, pl)

# ---- results -------------------------------------------------------------------------------------------------------------

def rs_encs(rs: List<&2, Rs>, acc: List<&2, Q.Enc>) -> Maybe<&2, List<&2, Q.Enc>>:
  match rs:
    case Nil{}:
      Some{List.reverse(&2, Q.Enc, acc)}
    case Con{h, tl}:
      match h:
        case REnc{e}:
          rs_encs(tl, e <> acc)
        case _:
          None{}

def rs_blocks(rs: List<&2, Rs>, acc: List<&2, List<&2, G.Vec>>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match rs:
    case Nil{}:
      Some{List.reverse(&2, List<&2, G.Vec>, acc)}
    case Con{h, tl}:
      match h:
        case RSy{s}:
          rs_blocks(tl, s <> acc)
        case _:
          None{}

def empty_dp() -> Dp:
  Dp{Nil{}, None{}, Nil{}, None{}}

def len_blocks(xs: List<&2, List<&2, G.Vec>>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, tl}:
      len_blocks(tl, (acc + 1 : U32))

# ---------------------------------------------------------------------------
# public API: encoding
# ---------------------------------------------------------------------------

# an encoded object: its OTI, layout and one encoder (intermediate symbols) per source block
type Obj is Data:
  Obj{oti: Oti, lay: Lay, encs: List<&2, Q.Enc>}

def obj_fin(m: Maybe<&2, List<&2, Q.Enc>>, +oti: Oti, +lay: Lay) -> Maybe<&2, Obj>:
  match m:
    case None{}:
      None{}
    case Some{es}:
      Some{Obj{oti, lay, es}}

def enc_syms.lay(lay: Lay, +mode: U32, +n: U32, +w: U32, +oti: Oti, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, Obj>:
  match lay:
    case Lay{+kt, +kl, +ks, +zl, +zs}:
      +z = (zl + zs : U32)
      obj_fin(rs_encs(run(w, z, Cx{mode, Blocks.oti_t(oti), zl, kl, ks, n, Blocks.enc_plans(kl, ks, zl, zs), empty_dp()}, PSrc{src}), Nil{}), oti, Lay{kt, kl, ks, zl, zs})

def enc_syms.go(ok: Bool, +w: U32, +oti: Oti, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, Obj>:
  match ok:
    case False{}:
      None{}
    case True{}:
      enc_syms.lay(Blocks.layout(oti), 0, 0, w, oti, src)

# Encode every source block (w workers; the plans are computed once per distinct K).  src = the K source symbols of every block
# (Blocks.split_object); None if the OTI is invalid or a block does not have the right symbol count.
def Blocks.encode_syms(+w: U32, +oti: Oti, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, Obj>:
  +s = src
  enc_syms.go(Blocks.valid(oti) && U32.is_eq(len_blocks(s, 0), Blocks.num_blocks(Blocks.layout(oti))), w, oti, s)

def Blocks.encode_object(+w: U32, +oti: Oti, data: List<&2, U32>) -> Maybe<&2, Obj>:
  +o = oti
  Blocks.encode_syms(w, o, Blocks.split_object(o, data))

# encoding symbol (sbn, esi): ESI < K the source symbol (systematic), ESI >= K a repair symbol.  None if sbn >= Z.
def sym_at(encs: List<&2, Q.Enc>, +sbn: U32, +esi: U32) -> Maybe<&2, G.Vec>:
  match encs:
    case Nil{}:
      None{}
    case Con{e, tl}:
      match sbn:
        case 0:
          Some{Q.Codec.symbol(e, esi)}
        case _:
          sym_at(tl, (sbn - 1 : U32), esi)

def Blocks.symbol(obj: Obj, +sbn: U32, +esi: U32) -> Maybe<&2, G.Vec>:
  match obj:
    case Obj{oti, lay, encs}:
      sym_at(encs, sbn, esi)

def rep_fin(m: Maybe<&2, List<&2, List<&2, G.Vec>>>) -> List<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      Nil{}
    case Some{bs}:
      bs

def rep_lay(lay: Lay, +w: U32, +n: U32, encs: List<&2, Q.Enc>) -> List<&2, List<&2, G.Vec>>:
  match lay:
    case Lay{kt, +kl, +ks, +zl, +zs}:
      +z = (zl + zs : U32)
      rep_fin(rs_blocks(run(w, z, Cx{1, 0, zl, kl, ks, n, Pp{None{}, None{}}, empty_dp()}, PEnc{encs}), Nil{}))

# n repair symbols (ESI K, K+1, ..) of every source block of an encoded object, one list per block (flat arena path of
# Codec.symbols, parallel over blocks)
def Blocks.repair(+w: U32, obj: Obj, +n: U32) -> List<&2, List<&2, G.Vec>>:
  match obj:
    case Obj{oti, lay, encs}:
      rep_lay(lay, w, n, encs)

def er_lay(lay: Lay, +w: U32, +n: U32, +oti: Oti, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match lay:
    case Lay{kt, +kl, +ks, +zl, +zs}:
      +z = (zl + zs : U32)
      rs_blocks(run(w, z, Cx{3, Blocks.oti_t(oti), zl, kl, ks, n, Blocks.enc_plans(kl, ks, zl, zs), empty_dp()}, PSrc{src}), Nil{})

def er_go(ok: Bool, +w: U32, +n: U32, +oti: Oti, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match ok:
    case False{}:
      None{}
    case True{}:
      er_lay(Blocks.layout(oti), w, n, oti, src)

# Encode and generate n repair symbols (ESI K ..) per block in one go, on the flat arena (no tree intermediate symbols, no Obj):
# the cheapest way to get the repair packets of a whole object.  Same symbols as Blocks.repair of Blocks.encode_syms.
def Blocks.encode_repair(+w: U32, +oti: Oti, +n: U32, src: List<&2, List<&2, G.Vec>>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  +s = src
  er_go(Blocks.valid(oti) && U32.is_eq(len_blocks(s, 0), Blocks.num_blocks(Blocks.layout(oti))), w, n, oti, s)

# ---------------------------------------------------------------------------
# public API: decoding
# ---------------------------------------------------------------------------

def dec_syms.lay(lay: Lay, +w: U32, +oti: Oti, pk: List<&2, Pkt>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match lay:
    case Lay{kt, +kl, +ks, +zl, +zs}:
      +z = (zl + zs : U32)
      +p = pk
      rs_blocks(run(w, z, Cx{2, Blocks.oti_t(oti), zl, kl, ks, 0, Pp{None{}, None{}}, Blocks.dec_plans(kl, ks, zl, zs, p)}, PPkt{p}), Nil{})

def dec_syms.go(ok: Bool, +w: U32, +oti: Oti, pk: List<&2, Pkt>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  match ok:
    case False{}:
      None{}
    case True{}:
      dec_syms.lay(Blocks.layout(oti), w, oti, pk)

# Decode every source block from the received packets (any order, any mix of source and repair symbols, packets of unknown blocks
# ignored): the K source symbols of each block.  None if the OTI is invalid or any block cannot be decoded (fewer than K symbols
# or rank deficient, RFC 5.4.2).  Blocks whose packets arrived with the same ESI sequence as the first block of their K class share
# that block's plan.
def Blocks.decode_syms(+w: U32, +oti: Oti, pkts: List<&2, Pkt>) -> Maybe<&2, List<&2, List<&2, G.Vec>>>:
  dec_syms.go(Blocks.valid(oti), w, oti, pkts)

def dec_obj.fin(m: Maybe<&2, List<&2, List<&2, G.Vec>>>, +oti: Oti) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      None{}
    case Some{bs}:
      Some{Blocks.join_object(oti, bs)}

# the F octets of the object
def Blocks.decode_object(+w: U32, +oti: Oti, pkts: List<&2, Pkt>) -> Maybe<&2, List<&2, U32>>:
  +o = oti
  dec_obj.fin(Blocks.decode_syms(w, o, pkts), o)
