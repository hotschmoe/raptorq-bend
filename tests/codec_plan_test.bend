# Plan / apply tests for the codec (src/raptorq.bend, docs/plan_apply.md): Codec.plan_for / Codec.encoder_plan /
# Codec.encode_with_plan / Codec.decode_with_plan (+ _auto) against the golden RFC vectors of tests/vectors and tests/vectors2
# (fixtures: tests/codec_fixtures.bend), and plan REUSE on a second payload of a different symbol size.
#  1. encoder: encode_with_plan(k, t, encoder_plan(k), source) gives every encoding symbol ESI 0..K+R-1 of the golden vectors
#     (K <= 1000 sets); with the SAME plan, a second payload with T + 12 octets must equal Codec.encoder on that payload
#     (K <= 100).
#  2. decoder: plan_for(k, esis) is None exactly on the golden failure cases, else decode_with_plan returns the source
#     symbols; the same plan decodes a second payload (T + 12 octets, produced by Codec.encoder) (K <= 100).
#  3. misfits: plan of another K, wrong number of symbols, too few ESIs, T = 0 give None; _auto variants agree.
# Run: bend tests/codec_plan_test.bend    Prints one line per case and ALL PASS; exits 1 on any failure.
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/tables.bend as T
import ../src/rfc_funcs.bend as R
import ../src/constraints.bend as C
import ../src/solver.bend as S
import ../src/raptorq.bend as Q
import ./codec_fixtures.bend as F

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def b2u(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0

def lst_eq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(U32.is_eq(x, y), lst_eq(xs, ys))
    case _ _:
      False{}

def veq(a: G.Vec, b: G.Vec) -> Bool:
  lst_eq(G.Vec.to_list(a, Nil{}), G.Vec.to_list(b, Nil{}))

def syms_eq(a: List<&2, G.Vec>, b: List<&2, G.Vec>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      band(veq(x, y), syms_eq(xs, ys))
    case _ _:
      False{}

def fail(b: Bool) -> U32:
  match b:
    case True{}:
      0
    case False{}:
      1

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def sp_of.go(m: Maybe<&2, T.SP>) -> T.SP:
  match m:
    case Some{sp}:
      sp
    case None{}:
      T.SP{0, 0, 0, 0, 0, 0}

def sp_of(+k: U32) -> T.SP:
  sp_of.go(R.params(k))

# n symbols of tw words, in order
def split_syms(n: Nat, +tw: Nat, xs: List<&2, U32>, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      List.reverse(&2, G.Vec, acc)
    case 1n+p:
      +ys = {xs : List<&2, U32>}
      split_syms(p, tw, List.drop(&2, U32, ys, tw), G.Vec.from_list(List.take(&2, U32, ys, tw)) <> acc)

# ---------------------------------------------------------------------------
# fixture cases
# ---------------------------------------------------------------------------

type Cs is Data:
  Cs{k: U32, t: U32, r: U32, syms: List<&2, G.Vec>, tr: C.ITree}

# [ncases] then per case [K, T, R, (K+R)*tw words]
def parse.go(n: Nat, xs: List<&2, U32>, acc: List<&2, Cs>) -> List<&2, Cs>:
  match n:
    case 0n:
      List.reverse(&2, Cs, acc)
    case 1n+p:
      match xs:
        case +k <> +t <> +r <> rest:
          +tw = U32.to_nat(U32.shrn((t + 3 : U32), 2n))
          +ns = (k + r : U32)
          +body = {rest : List<&2, U32>}
          +ss = split_syms(U32.to_nat(ns), tw, List.take(&2, U32, body, U32.to_nat((ns * U32.from_nat(tw) : U32))), Nil{})
          parse.go(p, List.drop(&2, U32, body, U32.to_nat((ns * U32.from_nat(tw) : U32))), Cs{k, t, r, ss, C.index(ss)} <> acc)
        case _:
          acc

def parse(xs: List<&2, U32>) -> List<&2, Cs>:
  match xs:
    case +n <> rest:
      parse.go(U32.to_nat(n), rest, Nil{})
    case _:
      Nil{}

def nth_case(xs: List<&2, Cs>, +i: U32) -> Cs:
  match xs:
    case Nil{}:
      Cs{0, 0, 0, Nil{}, C.INil{}}
    case Con{c, rest}:
      match i:
        case 0:
          c
        case _:
          nth_case(rest, (i - 1 : U32))


# ---------------------------------------------------------------------------
# helpers for the plan tests
# ---------------------------------------------------------------------------

def mb_syms_eq(a: Maybe<&2, List<&2, G.Vec>>, b: Maybe<&2, List<&2, G.Vec>>) -> Bool:
  match a b:
    case Some{x} Some{y}:
      syms_eq(x, y)
    case None{} None{}:
      True{}
    case _ _:
      False{}

def plan_none(m: Maybe<&2, S.Plan>) -> U32:
  match m:
    case None{}:
      1
    case Some{p}:
      0

def rnd_words(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      rnd_words(p, lcg(x), (x .^. U32.shrn(x, 7n) : U32) <> acc)

# n pseudo-random symbols of tw words
def rnd_syms(n: Nat, +tw: U32, +x: U32, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      List.reverse(&2, G.Vec, acc)
    case 1n+p:
      rnd_syms(p, tw, (x * 2654435761 + 12345 : U32), G.Vec.from_list(rnd_words(U32.to_nat(tw), x, [])) <> acc)

# symbols (data) for the ESIs of es from an encoder
def sym_of_enc(es: List<&2, U32>, +e: Q.Enc) -> List<&2, G.Vec>:
  match es:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      Q.Codec.symbol(e, x) <> sym_of_enc(rest, e)

def sym_of_tr(es: List<&2, U32>, +tr: C.ITree) -> List<&2, G.Vec>:
  match es:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      C.ix.get(tr, x, G.VNil{}) <> sym_of_tr(rest, tr)

def enc_syms(m: Maybe<&2, Q.Enc>, +n: U32) -> Maybe<&2, List<&2, G.Vec>>:
  match m:
    case None{}:
      None{}
    case Some{e}:
      Some{Q.Codec.symbols(e, 0, n)}

# ---------------------------------------------------------------------------
# 1. encoder
# ---------------------------------------------------------------------------

# bit0: golden mismatch, bit1: second payload differs from Codec.encoder (only checked when chk2)
def enc2_go(chk2: Bool, +k: U32, +t: U32, +n: U32, +plan: S.Plan) -> U32:
  match chk2:
    case False{}:
      0
    case True{}:
      +t2 = (t + 12 : U32)
      +src2 = rnd_syms(U32.to_nat(k), U32.shrn((t2 + 3 : U32), 2n), (k * 31 + t : U32), [])
      fail(mb_syms_eq(enc_syms(Q.Codec.encode_with_plan(k, t2, plan, src2), n), enc_syms(Q.Codec.encoder(k, t2, src2), n)))

def enc_case2(m: Maybe<&2, S.Plan>, +k: U32, +t: U32, +n: U32, +syms: List<&2, G.Vec>) -> U32:
  match m:
    case None{}:
      1
    case Some{+plan}:
      (fail(mb_syms_eq(enc_syms(Q.Codec.encode_with_plan(k, t, plan, List.take(&2, G.Vec, syms, U32.to_nat(k))), n), Some{syms})) + 2 * enc2_go(U32.is_le(k, 100), k, t, n, plan) : U32)

def enc_case(c: Cs) -> U32:
  match c:
    case Cs{+k, +t, +r, +syms, tr}:
      enc_case2(Q.Codec.encoder_plan(k), k, t, (k + r : U32), syms)

def enc_loop(cs: List<&2, Cs>, +i: U32, bad: U32, +tag: U32) -> IO(U32):
  match cs:
    case Nil{}:
      IO.pure(U32, bad)
    case Con{c, rest}:
      match c:
        case Cs{+k, +t, +r, +syms, tr}:
          +f = enc_case(Cs{k, t, r, syms, tr})
          do IO<U32>:
            IO.print("plan encoder set" ++ U32.show(tag) ++ " K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " esi 0.." ++ U32.show((k + r - 1 : U32)) ++ ": " ++ U32.show(f))
            enc_loop(rest, (i + 1 : U32), (bad + f : U32), tag)

# ---------------------------------------------------------------------------
# 2. decoder on the golden decode cases
# ---------------------------------------------------------------------------

# second payload: encoder on random source of T + 12 octets, decode from the same ESIs with the same plan
def dec2_fin(m: Maybe<&2, Q.Enc>, +k: U32, +t2: U32, plan: S.Plan, es: List<&2, U32>, src2: List<&2, G.Vec>) -> U32:
  match m:
    case None{}:
      1
    case Some{+e}:
      fail(mb_syms_eq(Q.Codec.decode_with_plan(k, t2, plan, sym_of_enc(es, e)), Some{src2}))

def dec2_go(chk2: Bool, +k: U32, +t: U32, +plan: S.Plan, +es: List<&2, U32>) -> U32:
  match chk2:
    case False{}:
      0
    case True{}:
      +t2 = (t + 12 : U32)
      +src2 = rnd_syms(U32.to_nat(k), U32.shrn((t2 + 3 : U32), 2n), (k * 17 + t : U32), [])
      dec2_fin(Q.Codec.encoder(k, t2, src2), k, t2, plan, es, src2)

def dec_ok(m: Maybe<&2, S.Plan>, +ok: U32, +k: U32, +t: U32, +es: List<&2, U32>, +tr: C.ITree, exp: List<&2, G.Vec>) -> U32:
  match m:
    case None{}:
      b2u(U32.is_eq(ok, 1))
    case Some{+plan}:
      match ok:
        case 1:
          (fail(mb_syms_eq(Q.Codec.decode_with_plan(k, t, plan, sym_of_tr(es, tr)), Some{exp})) + 2 * dec2_go(U32.is_le(k, 100), k, t, plan, es) : U32)
        case _:
          1

def dec_case(c: Cs, +ok: U32, es: List<&2, U32>) -> U32:
  match c:
    case Cs{+k, +t, r, +syms, +tr}:
      +e2 = {es : List<&2, U32>}
      dec_ok(Q.Codec.plan_for(k, e2), ok, k, t, e2, tr, List.take(&2, G.Vec, syms, U32.to_nat(k)))

# [ndec] then per case [case, ok, nrecv, esis...]
def dec_loop(n: Nat, +i: U32, +cs: List<&2, Cs>, xs: List<&2, U32>, bad: U32, +tag: U32) -> IO(U32):
  match n:
    case 0n:
      IO.pure(U32, bad)
    case 1n+p:
      match xs:
        case +ci <> +ok <> +nr <> rest:
          +body = {rest : List<&2, U32>}
          +c = nth_case(cs, ci)
          +f = dec_case(c, ok, List.take(&2, U32, body, U32.to_nat(nr)))
          do IO<U32>:
            IO.print("plan decode set" ++ U32.show(tag) ++ " #" ++ U32.show(i) ++ " case " ++ U32.show(ci) ++ " nrecv=" ++ U32.show(nr) ++ " ok=" ++ U32.show(ok) ++ ": " ++ U32.show(f))
            dec_loop(p, (i + 1 : U32), cs, List.drop(&2, U32, body, U32.to_nat(nr)), (bad + f : U32), tag)
        case _:
          IO.pure(U32, (bad + 1 : U32))

def dec_run(cs: List<&2, Cs>, xs: List<&2, U32>, +tag: U32) -> IO(U32):
  match xs:
    case +n <> rest:
      dec_loop(U32.to_nat(n), 0, cs, rest, 0, tag)
    case _:
      IO.pure(U32, 1)

# ---------------------------------------------------------------------------
# 3. misfits and the _auto variants
# ---------------------------------------------------------------------------

def is_none_syms(m: Maybe<&2, List<&2, G.Vec>>) -> U32:
  match m:
    case None{}:
      0
    case Some{e}:
      1

def is_none_enc(m: Maybe<&2, Q.Enc>) -> U32:
  match m:
    case None{}:
      0
    case Some{e}:
      1

def misfit_go(m10: Maybe<&2, S.Plan>, m20: Maybe<&2, S.Plan>) -> U32:
  match m10 m20:
    case Some{+p10} Some{+p20}:
      +s10 = rnd_syms(10n, 4, 5, [])
      +s20 = rnd_syms(20n, 4, 6, [])
      (is_none_enc(Q.Codec.encode_with_plan(20, 16, p10, s20)) + is_none_enc(Q.Codec.encode_with_plan(10, 16, p20, s10)) + is_none_enc(Q.Codec.encode_with_plan(10, 16, p10, List.take(&2, G.Vec, s20, 9n))) + is_none_enc(Q.Codec.encode_with_plan(10, 0, p10, s10)) + is_none_enc(Q.Codec.encode_with_plan(0, 16, p10, s10)) + is_none_syms(Q.Codec.decode_with_plan(10, 16, p10, List.take(&2, G.Vec, s10, 9n))) + is_none_syms(Q.Codec.decode_with_plan(20, 16, p10, s20)) : U32)
    case _ _:
      1

def misfits() -> U32:
  (misfit_go(Q.Codec.encoder_plan(10), Q.Codec.encoder_plan(20)) + (1 - plan_none(Q.Codec.plan_for(10, [0, 1, 2, 3, 4, 5, 6, 7, 8]))) + (1 - plan_none(Q.Codec.plan_for(0, []))) + (1 - plan_none(Q.Codec.plan_for(56404, [0]))) + (1 - plan_none(Q.Codec.plan_for(5, [0, 0, 0, 0, 0]))) : U32)

# encode_with_plan_auto / decode_with_plan_auto == the pure ones (T = 1024: slices the symbols with >= 2 threads)
def auto_go(+k: U32, +t: U32, +plan: S.Plan, +src: List<&2, G.Vec>) -> IO(U32):
  do IO<U32>:
    m : Maybe<&2, Q.Enc> <- Q.Codec.encode_with_plan_auto(k, t, plan, src)
    +a : U32 <- IO.pure(U32, fail(mb_syms_eq(enc_syms(m, (k + 5 : U32)), enc_syms(Q.Codec.encoder(k, t, src), (k + 5 : U32)))))
    IO.print("auto encode K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ ": " ++ U32.show(a))
    IO.pure(U32, a)

def auto_run(m: Maybe<&2, S.Plan>, +k: U32, +t: U32) -> IO(U32):
  match m:
    case None{}:
      IO.pure(U32, 1)
    case Some{+plan}:
      auto_go(k, t, plan, rnd_syms(U32.to_nat(k), U32.shrn((t + 3 : U32), 2n), 99, []))

def auto_dec2(m: Maybe<&2, Q.Enc>, +k: U32, +t: U32, +plan: S.Plan, +es: List<&2, U32>) -> IO(U32):
  match m:
    case None{}:
      IO.pure(U32, 1)
    case Some{+e}:
      do IO<U32>:
        r : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_with_plan_auto(k, t, plan, sym_of_enc(es, e))
        +a : U32 <- IO.pure(U32, fail(mb_syms_eq(r, Q.Codec.decode_with_plan(k, t, plan, sym_of_enc(es, e)))))
        IO.print("auto decode K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ ": " ++ U32.show(a))
        IO.pure(U32, a)

def auto_dec(m: Maybe<&2, S.Plan>, +k: U32, +t: U32, +es: List<&2, U32>) -> IO(U32):
  match m:
    case None{}:
      IO.pure(U32, 1)
    case Some{+plan}:
      auto_dec2(Q.Codec.encoder(k, t, rnd_syms(U32.to_nat(k), U32.shrn((t + 3 : U32), 2n), 7, [])), k, t, plan, es)

# n ESIs hi, hi-1, ..., prepended: ascending
def esi_list(n: Nat, +hi: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      esi_list(p, (hi - 1 : U32), hi <> acc)

def finish(bad: U32) -> IO(Unit):
  match bad:
    case 0:
      IO.print("ALL PASS")
    case _:
      IO.die(Unit, 1, "FAILED: " ++ U32.show(bad))

def main() -> IO(Unit):
  do IO<Unit>:
    e1 : U32 <- enc_loop(parse(F.enc()), 0, 0, 1)
    e2 : U32 <- enc_loop(parse(F.enc2()), 0, 0, 2)
    d1 : U32 <- dec_run(parse(F.enc()), F.dec(), 1)
    d2 : U32 <- dec_run(parse(F.enc2()), F.dec2(), 2)
    +mf : U32 <- IO.pure(U32, misfits())
    IO.print("misfits: " ++ U32.show(mf))
    a1 : U32 <- auto_run(Q.Codec.encoder_plan(30), 30, 1024)
    a2 : U32 <- auto_dec(Q.Codec.plan_for(30, esi_list(32n, 61, [])), 30, 1024, esi_list(32n, 61, []))
    finish((e1 + e2 + d1 + d2 + mf + a1 + a2 : U32))
