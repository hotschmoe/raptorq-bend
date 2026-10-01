# Codec benchmark (docs/benchmarks.md): encoder setup (intermediate symbols), N repair symbols, decode from K symbols.
#   bend tools/bench/bench.bend -o build/bench     (put /usr/bin first in PATH, see CLAUDE.md)
#   ./build/bench [--threads N] -- <K> <T octets> <N repair symbols>
# Prints one line:  BEND K=.. T=.. N=.. threads=.. setup_ms=.. repair_ms=.. repair_walk_ms=.. decode_ms=.. ok=1
# repair_ms = Codec.symbols_auto call (strict: forcing the list spine forces the symbols), repair_walk_ms = the harness checksum walk afterwards (NOT in repair_ms);
# decode_ms = Codec.decode_auto call only, the verification against the source is outside the clock.
# The decode input is K symbols: every 8th ESI is a source symbol, the rest are repair symbols (ESI >= K).
# Uses Codec.encoder_auto / decode_auto (slicing over the threads for T >= 256).  Always an IO main (native binary).
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/raptorq.bend as Q

type Tm is Data:
  Tm{a: Nat, b: Nat}

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

def rcv.go(n: Nat, +i: U32, +k: U32, +e: Q.Enc, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +esi = pick(U32.is_eq((i .&. 7 : U32), 0), i, k)
      rcv.go(p, (i - 1 : U32), k, e, Y.Rcv{esi, Q.Codec.symbol(e, esi)} <> acc)

def b2u(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0

def verdict(res: Maybe<&2, List<&2, G.Vec>>, src: List<&2, G.Vec>) -> U32:
  match res:
    case None{}:
      0
    case Some{out}:
      b2u(syms_eq(out, src))

def report(+k: U32, +t: U32, +n: U32, +thr: U32, +setup: Nat, +rep: Nat, +repw: Nat, +dec: Nat, +ok: U32) -> IO(Unit):
  IO.print("BEND K=" ++ U32.show(k) ++ " T=" ++ U32.show(t) ++ " N=" ++ U32.show(n) ++ " threads=" ++ U32.show(thr) ++ " setup_ms=" ++ Nat.show(setup) ++ " repair_ms=" ++ Nat.show(rep) ++ " repair_walk_ms=" ++ Nat.show(repw) ++ " decode_ms=" ++ Nat.show(dec) ++ " ok=" ++ U32.show(ok))

def len_syms(xs: List<&2, G.Vec>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      len_syms(t, (acc + 1 : U32))

def len_res(r: Maybe<&2, List<&2, G.Vec>>) -> U32:
  match r:
    case None{}:
      0
    case Some{xs}:
      len_syms(xs, 0)

def decode_phase(+e: Q.Enc, +k: U32, +t: U32, +n: U32, +thr: U32, +setup: Nat, +rep: Nat, +repw: Nat, src: List<&2, G.Vec>) -> IO(Unit):
  +rv = rcv.go(U32.to_nat(k), (k - 1 : U32), k, e, [])
  do IO<Unit>:
    IO.print("received built, checksum " ++ U32.show(fold_rcv(rv, 0)))
    +t2 : Nat <- IO.now()
    +res : Maybe<&2, List<&2, G.Vec>> <- Q.Codec.decode_auto(k, t, rv)
    +nres : U32 <- IO.pure(U32, len_res(res))
    +t3 : Nat <- IO.now()
    +ok : U32 <- IO.pure(U32, verdict(res, src))
    IO.print("decode ok=" ++ U32.show(ok) ++ " symbols=" ++ U32.show(nres))
    report(k, t, n, thr, setup, rep, repw, (t3 - t2 : Nat), ok)

# mode 1 reports the flat API's setup / repair times instead of the tree API's (the tree ones are still measured)
def pick_phase(+mode: U32, fl: Tm, +e: Q.Enc, +k: U32, +t: U32, +n: U32, +thr: U32, +setup: Nat, +rep: Nat, +repw: Nat, src: List<&2, G.Vec>) -> IO(Unit):
  match mode:
    case 1:
      match fl:
        case Tm{a, b}:
          decode_phase(e, k, t, n, thr, a, b, 0n, src)
    case _:
      decode_phase(e, k, t, n, thr, setup, rep, repw, src)

def enc_phase(m: Maybe<&2, Q.Enc>, +k: U32, +t: U32, +n: U32, +thr: U32, +t0: Nat, +fl: Tm, +mode: U32, src: List<&2, G.Vec>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: encoder returned None")
    case Some{+e}:
      do IO<Unit>:
        IO.print("first repair symbol checksum " ++ U32.show(fold_syms(Q.Codec.symbols(e, k, 1), 0)))
        +t1 : Nat <- IO.now()
        +rs : List<&2, G.Vec> <- Q.Codec.symbols_auto(e, k, n)
        +nrs : U32 <- IO.pure(U32, len_syms(rs, 0))
        +t2 : Nat <- IO.now()
        IO.print("repair symbols " ++ U32.show(nrs) ++ " checksum " ++ U32.show(fold_syms(rs, 0)))
        +t3 : Nat <- IO.now()
        pick_phase(mode, fl, e, k, t, n, thr, (t1 - t0 : Nat), (t2 - t1 : Nat), (t3 - t2 : Nat), src)

# mode 1: setup and repair are measured on the LINEAR FLAT encoder (Codec.encoder_flat_auto + symbols_flat, result summed in place);
# the decode phase still needs received symbols, which are built (untimed) with the Data encoder.
def flat_c(g: Q.GenF, +n: U32, +t0: Nat, +t1: Nat) -> IO(Tm):
  match g:
    case Q.GenF{e, o}:
      do IO<Tm>:
        +c : U32 <- IO.pure(U32, Q.Codec.out_sum(n, o))
        +t2 : Nat <- IO.now()
        IO.pure(Tm, Tm{(t1 - t0 : Nat), (t2 - t1 : Nat)})

def flat_b(g: Q.GenF, +k: U32, +n: U32, +t0: Nat) -> IO(Tm):
  match g:
    case Q.GenF{e, o}:
      do IO<Tm>:
        +c : U32 <- IO.pure(U32, Q.Codec.out_sum(1, o))
        +t1 : Nat <- IO.now()
        g2 : Q.GenF <- IO.pure(Q.GenF, Q.Codec.symbols_flat(e, k, n))
        flat_c(g2, n, t0, t1)

def flat_a(m: Q.MbF, +k: U32, +n: U32, +t0: Nat) -> IO(Tm):
  match m:
    case Q.NoF{}:
      IO.die(Tm, 1, "FAIL: encoder_flat returned NoF")
    case Q.SomeF{e}:
      flat_b(Q.Codec.symbols_flat(e, k, 1), k, n, t0)

def flat_phase(+k: U32, +t: U32, +n: U32, src: List<&2, G.Vec>) -> IO(Tm):
  do IO<Tm>:
    +t0 : Nat <- IO.now()
    m : Q.MbF <- Q.Codec.encoder_flat_auto(k, t, {src : List<&2, G.Vec>})
    flat_a(m, k, n, t0)

def flat_phase_mode(+mode: U32, +k: U32, +t: U32, +n: U32, src: List<&2, G.Vec>) -> IO(Tm):
  match mode:
    case 1:
      flat_phase(k, t, n, src)
    case _:
      IO.pure(Tm, Tm{0n, 0n})

def bench(+k: U32, +t: U32, +n: U32, +mode: U32) -> IO(Unit):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  do IO<Unit>:
    +thr : U32 <- IO.thread_count()
    IO.print("source built, checksum " ++ U32.show(fold_syms(src, 0)))
    +fl : Tm <- flat_phase_mode(mode, k, t, n, src)
    +t0 : Nat <- IO.now()
    m : Maybe<&2, Q.Enc> <- Q.Codec.encoder_auto(k, t, {src : List<&2, G.Vec>})
    enc_phase(m, k, t, n, thr, t0, fl, mode, src)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ts <> ns <> ms <> rest:
      bench(rd(ks, 1000), rd(ts, 16), rd(ns, 1000), rd(ms, 0))
    case prog <> ks <> ts <> ns <> rest:
      bench(rd(ks, 1000), rd(ts, 16), rd(ns, 1000), 0)
    case _:
      IO.die(Unit, 1, "usage: bench [--threads N] -- K T N [mode: 0 tree API, 1 linear flat API]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
