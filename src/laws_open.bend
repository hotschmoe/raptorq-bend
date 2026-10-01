# Laws the codec must satisfy that are NOT proven (docs/proofs.md has the status table).
# They are kept out of LAWS.bend so that `bend PROOF.bend` stays an honest gate: every open law makes
# `bend src/laws_open.bend` print SOME PROOFS FAIL, which is expected here (scripts/check_proofs.sh counts them).
# Each one is covered by a runtime check (src/laws_check.bend) or by the exhaustive / differential tests listed in
# docs/proofs.md.  Moving one into LAWS.bend + PROOF.bend is how it graduates.
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./raptorq.bend as Q
import ./laws_verify.bend as V

# an octet is a U32 below 256
def Oct(a: U32) -> Type:
  {U32.is_lt(a, 256) == True{} : Bool}

# every element is a byte
def Bytes(xs: List<&2, U32>) -> Type:
  match xs:
    case Nil{}:
      Unit
    case Con{h, t}:
      Oct(h) & Bytes(t)

# every symbol has this many packed words (ceil(T/4))
def AllWords(ss: List<&2, G.Vec>, tw: Nat) -> Type:
  match ss:
    case Nil{}:
      Unit
    case Con{v, rest}:
      {List.length(&2, U32, G.Vec.to_list(v, Nil{})) == tw : Nat} & AllWords(rest, tw)

# every received symbol is the encoder's symbol for its ESI
def Genuine(enc: Q.Enc, rv: List<&2, Y.Rcv>) -> Type:
  match rv:
    case Nil{}:
      Unit
    case Con{r, rest}:
      match r:
        case Y.Rcv{esi, sym}:
          {Q.Codec.symbol(enc, esi) == sym : G.Vec} & Genuine(enc, rest)

# a decode outcome is acceptable when it is None (rank deficient) or the source
def Rt(r: Maybe<&2, List<&2, G.Vec>>, src: List<&2, G.Vec>) -> Type:
  match r:
    case None{}:
      Unit
    case Some{out}:
      {out == src : List<&2, G.Vec>}

# ---- Rand / parameters (runtime-checked: src/laws_check.bend) ---------------------

law rand_bound:
  for +y: U32
  for +i: U32
  for +m: U32
  for  h: {U32.is_gt(m, 0) == True{} : Bool}
  {U32.is_lt(R.rand(y, i, m), m) == True{} : Bool}

law params_ge:
  for +k: U32
  for +sp: T.SP
  for  h: {R.params(k) == Some{sp} : Maybe<&2, T.SP>}
  {U32.is_le(k, R.Kp(sp)) == True{} : Bool}

# K' is the smallest Table 2 value >= K
law params_smallest:
  for +k: U32
  for +k2: U32
  for +sp: T.SP
  for +sp2: T.SP
  for  h: {R.params(k) == Some{sp} : Maybe<&2, T.SP>}
  for  h2: {R.params(k2) == Some{sp2} : Maybe<&2, T.SP>}
  for  h3: {U32.is_eq(R.Kp(sp2), k2) == True{} : Bool}
  for  h4: {U32.is_le(k, k2) == True{} : Bool}
  {U32.is_le(R.Kp(sp), k2) == True{} : Bool}

# ---- GF(256) field laws (exhaustive 256x256 tests: tests/gf256_test.bend) -------------

law mul_comm:
  for +a: U32
  for +b: U32
  for  ha: Oct(a)
  for  hb: Oct(b)
  {G.mul(a, b) == G.mul(b, a) : U32}

law mul_assoc:
  for +a: U32
  for +b: U32
  for +c: U32
  for  ha: Oct(a)
  for  hb: Oct(b)
  for  hc: Oct(c)
  {G.mul(G.mul(a, b), c) == G.mul(a, G.mul(b, c)) : U32}

law mul_dist:
  for +a: U32
  for +b: U32
  for +c: U32
  for  ha: Oct(a)
  for  hb: Oct(b)
  for  hc: Oct(c)
  {G.mul(a, G.add(b, c)) == G.add(G.mul(a, b), G.mul(a, c)) : U32}

law mul_one:
  for +a: U32
  for  ha: Oct(a)
  {G.mul(1, a) == a : U32}

law mul_inv:
  for +a: U32
  for  ha: Oct(a)
  for  hz: {U32.is_ne(a, 0) == True{} : Bool}
  {G.mul(a, G.inv(a)) == 1 : U32}

# ---- Codec ------------------------------------------------------------------------

law split_symbol_words:
  for +data: List<&2, U32>
  for +t: U32
  for  hb: Bytes(data)
  for  ht: {U32.is_gt(t, 0) == True{} : Bool}
  AllWords(Q.Codec.split(data, t), U32.to_nat(U32.shrn((t + 3 : U32), 2n)))

law join_split:
  for +data: List<&2, U32>
  for +t: U32
  for  hb: Bytes(data)
  for  ht: {U32.is_gt(t, 0) == True{} : Bool}
  {Q.Codec.join(Q.Codec.split(data, t), t, Q.len_u32(data, 0)) == data : List<&2, U32>}

# Roundtrip: whatever subset of the encoder's symbols arrives, decode either reports failure
# (rank deficient, RFC 5.4.2) or returns exactly the source symbols.  (Not claimed: success.)
law roundtrip:
  for +k: U32
  for +t: U32
  for +src: List<&2, G.Vec>
  for +enc: Q.Enc
  for +rv: List<&2, Y.Rcv>
  for  he: {Q.Codec.encoder(k, t, src) == Some{enc} : Maybe<&2, Q.Enc>}
  for  hr: Genuine(enc, rv)
  Rt(Q.Codec.decode(k, t, rv), src)

# decode_checked only answers with source symbols whose re-encoding reproduces every received symbol
law decode_checked_consistent:
  for +k: U32
  for +t: U32
  for +rv: List<&2, Y.Rcv>
  for +out: List<&2, G.Vec>
  for +enc: Q.Enc
  for  h: {V.Codec.decode_checked(k, t, rv) == Some{out} : Maybe<&2, List<&2, G.Vec>>}
  for  he: {Q.Codec.encoder(k, t, out) == Some{enc} : Maybe<&2, Q.Enc>}
  Genuine(enc, rv)
