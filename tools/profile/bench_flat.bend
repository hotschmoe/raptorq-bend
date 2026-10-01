# Stage timings of flat repair generation (src/flat.bend): intermediate symbols -> array, XOR loops + read-out, checksum walk.
#   bend tools/profile/bench_flat.bend -o build/bench_flat ; taskset -c 11 ./build/bench_flat --threads 1 -- <K> <T> <N>
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as T
import ../../src/rfc_funcs.bend as R
import ../../src/constraints.bend as C
import ../../src/flat.bend as F
import ../../src/raptorq.bend as Q

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

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

def ck.fin(r: Array<U32> & U32, +i: U32) -> U32:
  (a, x) = r
  (x + i : U32)

def ck_fi(f: F.Fi) -> U32:
  match f:
    case F.Fi{i, a}:
      ck.fin(Array.get(U32, a, 0), i)

# the head symbol of the list depends (through the threaded array) on every earlier step
def head_sum(xs: List<&2, G.Vec>) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{v, _}:
      fold_words(G.Vec.to_list(v, Nil{}), 0)

# XOR loops only (no read-out into Vecs)
def g2(+n: Nat, +esi: U32, +k: U32, +sp: T.SP, +w: Nat, +wu: U32, +ob: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      g2(q, U32.inc(esi), k, sp, w, wu, ob, F.Flat.enc.start(C.lt_terms(sp, C.isi_of(esi, k, R.Kp(sp))), w, wu, ob, a))

def ck_a(a: Array<U32>, +ob: U32) -> U32:
  ck.fin(Array.get(U32, a, ob), 0)

def go(m: Maybe<&2, Q.Enc>, +n: U32) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "None")
    case Some{+e}:
      match e:
        case Q.Enc{+k, t, +sp, +tr}:
          +wu = F.Flat.words_of_tree(tr)
          do IO<Unit>:
            +t0 : Nat <- IO.now()
            +a1 : U32 <- IO.pure(U32, ck_fi(F.Flat.tfill(tr, wu, F.Flat.arena(R.L(sp), wu))))
            IO.print("tfill checksum " ++ U32.show(a1))
            +t1 : Nat <- IO.now()
            +c3 : U32 <- IO.pure(U32, ck_a(g2(U32.to_nat(n), k, k, sp, U32.to_nat(wu), wu, (R.L(sp) * wu : U32), F.Flat.fi_arr(F.Flat.tfill(tr, wu, F.Flat.arena(R.L(sp), wu)))), (R.L(sp) * wu : U32)))
            IO.print("xor-only checksum " ++ U32.show(c3))
            +tx : Nat <- IO.now()
            IO.print("RESULT tfill+xor_ms=" ++ Nat.show((tx - t1 : Nat)))
            +t1 : Nat <- IO.now()
            +lst : List<&2, G.Vec> <- IO.pure(List<&2, G.Vec>, F.Flat.encode_tree(sp, k, tr, k, n))
            +c2 : U32 <- IO.pure(U32, head_sum(lst))
            IO.print("gen (incl tfill) last word " ++ U32.show(c2))
            +t2 : Nat <- IO.now()
            IO.print("fold " ++ U32.show(fold_syms(lst, 0)))
            +t3 : Nat <- IO.now()
            IO.print("RESULT tfill_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " tfill+gen+out_ms=" ++ Nat.show((t2 - t1 : Nat)) ++ " fold_ms=" ++ Nat.show((t3 - t2 : Nat)))

def bench(+k: U32, +t: U32, +n: U32) -> IO(Unit):
  +data = bytes.go(U32.to_nat((k * t : U32)), (k * 65536 + t : U32), [])
  +src = Q.Codec.split(data, t)
  go(Q.Codec.encoder(k, t, src), n)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ts <> ns <> rest:
      bench(rd(ks, 1000), rd(ts, 1024), rd(ns, 1000))
    case _:
      bench(1000, 1024, 1000)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
