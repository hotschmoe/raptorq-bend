# Plan/apply benchmark (docs/plan_apply.md): the encoder plan once per K and applied to two source blocks of the
# same size, and the decoder plan for one loss pattern applied to two payloads.
#   bend tests/codec_plan_bench.bend -o pb     (put /usr/bin first in PATH, see CLAUDE.md)
#   ./pb [--threads N] -- <K> <T octets> <N repair symbols>
# Prints one line: BENDP K=.. T=.. N=.. threads=.. plan_ms=.. enc1_ms=.. enc2_ms=.. dplan_ms=.. dec1_ms=.. dec2_ms=.. ok=..
#   plan_ms  = Codec.encoder_plan(K)  (N is unused, kept for the same command line as tools/bench)      enc1_ms / enc2_ms = Codec.encode_with_plan_auto on block 1 / block 2 
#   dplan_ms = Codec.plan_for(K, esis)    dec1_ms / dec2_ms = Codec.decode_with_plan_auto on payload 1 / payload 2
# The decode input is K symbols: every 8th ESI is a source symbol, the rest are repair symbols (ESI >= K), as in tools/bench.
# Old-code equivalents: setup_ms (= plan_ms + enc1_ms) and decode_ms of tools/bench/bench.bend.
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/solver.bend as S
import ../src/raptorq.bend as Q

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def bytes.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      bytes.go(p, lcg(x), U32.shrn(lcg(x), 24n) <> acc)

def fold_words(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, tl}:
      fold_words(tl, (acc * 31 + h : U32))

def fold_syms(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{v, tl}:
      fold_syms(tl, (acc * 31 + fold_words(G.Vec.to_list(v, Nil{}), 0) : U32))

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
      band(lst_eq(G.Vec.to_list(x, Nil{}), G.Vec.to_list(y, Nil{})), syms_eq(xs, ys))
    case _ _:
      False{}

def fold_rcv(xs: List<&2, Y.Rcv>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{r, tl}:
      match r:
        case Y.Rcv{esi, sym}:
          fold_rcv(tl, (acc * 31 + fold_words(G.Vec.to_list(sym, Nil{}), esi) : U32))

def pick(b: Bool, +i: U32, +k: U32) -> U32:
  match b:
    case True{}:
      i
    case False{}:
      (k + i : U32)

def b2u(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0


def lg_len(xs: List<&2, S.Lg>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      lg_len(t, (acc + 1 : U32))

def tm_len(xs: List<&2, Y.Term>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      tm_len(t, (acc + 1 : U32))

def pp_size(xs: List<&2, S.PP>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case S.PP{id, pc, finv, log, oc} <> t:
      pp_size(t, (acc + 1 + lg_len(log, 0) + tm_len(oc, 0) : U32))

def tr_size(xs: List<&2, S.TR>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case S.TR{id, log} <> t:
      tr_size(t, (acc + 1 + lg_len(log, 0) : U32))

def tc_size(xs: List<&2, S.TC>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case S.TC{col, ts} <> t:
      tc_size(t, (acc + 1 + tm_len(ts, 0) : U32))

# forces the whole plan
def plan_size(m: Maybe<&2, S.Plan>) -> U32:
  match m:
    case None{}:
      0
    case Some{pl}:
      match pl:
        case S.Plan{l, nrows, npiv, ntr, pivs, trs, tail}:
          (pp_size(pivs, 0) + tr_size(trs, 0) + tc_size(tail, 0) : U32)

# ESIs of the decode pattern (ascending)
def esi.go(n: Nat, +i: U32, +k: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      esi.go(p, (i - 1 : U32), k, pick(U32.is_eq((i .&. 7 : U32), 0), i, k) <> acc)

def sym_of(es: List<&2, U32>, +e: Q.Enc) -> List<&2, G.Vec>:
  match es:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      Q.Codec.symbol(e, x) <> sym_of(rest, e)

def verdict(res: Maybe<&2, List<&2, G.Vec>>, src: List<&2, G.Vec>) -> U32:
  match res:
    case None{}:
      0
    case Some{out}:
      b2u(syms_eq(out, src))

# checksum of one repair symbol (as tools/bench/bench.bend does: forces the intermediate symbols)
def enc_fold(m: Maybe<&2, Q.Enc>, +k: U32, +n: U32) -> U32:
  match m:
    case None{}:
      0
    case Some{e}:
      fold_syms(Q.Codec.symbols(e, k, 1), 0)

def report(+k: U32, +t: U32, +n: U32, +thr: U32, +plan: Nat, +e1: Nat, +e2: Nat, +dplan: Nat, +d1: Nat, +d2: Nat, +ok: U32) -> IO(Unit):
  IO.print("BENDP K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " N=" ++ U32.show(n) ++ " threads=" ++ U32.show(thr) ++ " plan_ms=" ++ Nat.show(plan) ++ " enc1_ms=" ++ Nat.show(e1) ++ " enc2_ms=" ++ Nat.show(e2) ++ " dplan_ms=" ++ Nat.show(dplan) ++ " dec1_ms=" ++ Nat.show(d1) ++ " dec2_ms=" ++ Nat.show(d2) ++ " ok=" ++ U32.show(ok))

# ---- stage 3: decoder -------------------------------------------------------------------------------------------
def dec_last(+k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +e1m: Nat, +e2m: Nat, +dpm: Nat, +d1m: Nat, +ok1: U32, e2: Q.Enc, +es: List<&2, U32>, +dp: S.Plan, src2: List<&2, G.Vec>) -> IO(Unit):
  +syms2 = sym_of(es, e2)
  do IO<Unit>:
    IO.print("payload 2 symbols built, checksum " ++ U32.show(fold_syms(syms2, 0)))
    +t4 : Nat <- IO.now()
    r2 : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_with_plan_auto(k, t, dp, syms2)
    +ok2 : U32 <- IO.pure(U32, verdict(r2, src2))
    IO.print("decode 2 ok=" ++ U32.show(ok2))
    +t5 : Nat <- IO.now()
    report(k, t, n, thr, pm, e1m, e2m, dpm, d1m, (t5 - t4 : Nat), b2u(band(U32.is_eq(ok1, 1), U32.is_eq(ok2, 1))))

def dec_mid(+k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +e1m: Nat, +e2m: Nat, +dpm: Nat, e1: Q.Enc, e2: Q.Enc, +es: List<&2, U32>, +dp: S.Plan, src1: List<&2, G.Vec>, src2: List<&2, G.Vec>) -> IO(Unit):
  +syms1 = sym_of(es, e1)
  do IO<Unit>:
    IO.print("payload 1 symbols built, checksum " ++ U32.show(fold_syms(syms1, 0)))
    +t2 : Nat <- IO.now()
    r1 : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_with_plan_auto(k, t, dp, syms1)
    +ok1 : U32 <- IO.pure(U32, verdict(r1, src1))
    IO.print("decode 1 ok=" ++ U32.show(ok1))
    +t3 : Nat <- IO.now()
    dec_last(k, t, n, thr, pm, e1m, e2m, dpm, (t3 - t2 : Nat), ok1, e2, es, dp, src2)

# decoder plan for the pattern
def dec_plan2(dpmaybe: Maybe<&2, S.Plan>, +k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +e1m: Nat, +e2m: Nat, +dpm: Nat, e1: Q.Enc, e2: Q.Enc, +es: List<&2, U32>, src1: List<&2, G.Vec>, src2: List<&2, G.Vec>) -> IO(Unit):
  match dpmaybe:
    case None{}:
      IO.die(Unit, 1, "FAIL: decoder plan is None")
    case Some{+dp}:
      dec_mid(k, t, n, thr, pm, e1m, e2m, dpm, e1, e2, es, dp, src1, src2)

def dec_plan(+k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +e1m: Nat, +e2m: Nat, e1: Q.Enc, e2: Q.Enc, src1: List<&2, G.Vec>, src2: List<&2, G.Vec>) -> IO(Unit):
  +es = esi.go(U32.to_nat(k), (k - 1 : U32), k, [])
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +dp : Maybe<&2, S.Plan> <- IO.pure(Maybe<&2, S.Plan>, Q.Codec.plan_for(k, es))
    IO.print("decoder plan size " ++ U32.show(plan_size(dp)))
    +t1 : Nat <- IO.now()
    dec_plan2(dp, k, t, n, thr, pm, e1m, e2m, (t1 - t0 : Nat), e1, e2, es, src1, src2)

def enc_dec(m1: Maybe<&2, Q.Enc>, m2: Maybe<&2, Q.Enc>, +k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +e1m: Nat, +e2m: Nat, src1: List<&2, G.Vec>, src2: List<&2, G.Vec>) -> IO(Unit):
  match m1 m2:
    case Some{e1} Some{e2}:
      dec_plan(k, t, n, thr, pm, e1m, e2m, e1, e2, src1, src2)
    case _ _:
      IO.die(Unit, 1, "FAIL: encode_with_plan returned None")

# ---- stage 2: two source blocks with the same plan ----------------------------------------------------------------
def enc_two(+k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +e1m: Nat, m1: Maybe<&2, Q.Enc>, +plan: S.Plan, src1: List<&2, G.Vec>, +src2: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    +t2 : Nat <- IO.now()
    m2 : Maybe<&2, Q.Enc> <- Q.Codec.encode_with_plan_auto(k, t, plan, {src2 : List<&2, G.Vec>})
    +m2c : Maybe<&2, Q.Enc> <- IO.pure(Maybe<&2, Q.Enc>, m2)
    IO.print("block 2 checksum " ++ U32.show(enc_fold(m2c, k, n)))
    +t3 : Nat <- IO.now()
    enc_dec(m1, m2c, k, t, n, thr, pm, e1m, (t3 - t2 : Nat), src1, src2)

def enc_one(+k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, +plan: S.Plan, +src1: List<&2, G.Vec>, +src2: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    m1 : Maybe<&2, Q.Enc> <- Q.Codec.encode_with_plan_auto(k, t, plan, {src1 : List<&2, G.Vec>})
    +m1c : Maybe<&2, Q.Enc> <- IO.pure(Maybe<&2, Q.Enc>, m1)
    IO.print("block 1 checksum " ++ U32.show(enc_fold(m1c, k, n)))
    +t2 : Nat <- IO.now()
    enc_two(k, t, n, thr, pm, (t2 - t1 : Nat), m1c, plan, src1, src2)

def plan_stage(pmaybe: Maybe<&2, S.Plan>, +k: U32, +t: U32, +n: U32, +thr: U32, +pm: Nat, src1: List<&2, G.Vec>, src2: List<&2, G.Vec>) -> IO(Unit):
  match pmaybe:
    case None{}:
      IO.die(Unit, 1, "FAIL: encoder plan is None")
    case Some{plan}:
      enc_one(k, t, n, thr, pm, plan, src1, src2)

def bench(+k: U32, +t: U32, +n: U32) -> IO(Unit):
  +src1 = Q.Codec.split(bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), []), t)
  +src2 = Q.Codec.split(bytes.go(U32.to_nat((k * t : U32)), (k * 4099 + t + 7 : U32), []), t)
  do IO<Unit>:
    +thr : U32 <- IO.thread_count()
    IO.print("sources built, checksum " ++ U32.show(fold_syms(src1, 0)) ++ " " ++ U32.show(fold_syms(src2, 0)))
    +t0 : Nat <- IO.now()
    +pl : Maybe<&2, S.Plan> <- IO.pure(Maybe<&2, S.Plan>, Q.Codec.encoder_plan(k))
    IO.print("encoder plan size " ++ U32.show(plan_size(pl)))
    +t1 : Nat <- IO.now()
    plan_stage(pl, k, t, n, thr, (t1 - t0 : Nat), src1, src2)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ts <> ns <> rest:
      bench(rd(ks, 1000), rd(ts, 16), rd(ns, 20))
    case _:
      IO.die(Unit, 1, "usage: pb [--threads N] -- K T N")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
