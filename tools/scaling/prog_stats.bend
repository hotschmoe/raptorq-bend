# Instruction mix of the compiled program of the encoder plan: counts of copy, xor (axpy c = 1), multiply-add (axpy c > 1), axset, scale, zero.
#   bend tools/scaling/prog_stats.bend -o build/scaling/prog_stats ; ./build/scaling/prog_stats -- <K>
import Base
import ../../src/gf256.bend as G
import ../../src/tables.bend as TB
import ../../src/rfc_funcs.bend as R
import ../../src/solver.bend as S
import ../../src/raptorq.bend as Q

type Cnt is Type:
  Cnt{p: Array<U32>, cn: Array<U32>}

def bump.f(+i: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, y) = rd
  Array.set(U32, a, i, (y + 1 : U32))

def bump(+i: U32, a: Array<U32>) -> Array<U32>:
  bump.f(i, Array.get(U32, a, i))

def cls(+k: U32, +c: U32) -> U32:
  match k:
    case 0:
      0
    case 1:
      match c:
        case 1:
          1
        case _:
          2
    case _:
      (k + 1 : U32)

def stp(cn: Array<U32>, rd: Array<U32> & U32) -> Cnt:
  (p, +x) = rd
  Cnt{p, bump(cls(U32.and(x, 255), U32.shrn(x, 8n)), cn)}

def step(+i: U32, st: Cnt) -> Cnt:
  match st:
    case Cnt{p, cn}:
      stp(cn, Array.get(U32, p, i))

def loop(+n: Nat, +i: U32, st: Cnt) -> Cnt:
  match n:
    case 0n:
      st
    case 1n+q:
      loop(q, (i + 3 : U32), step(i, st))

def r5(+x0: U32, +x1: U32, +x2: U32, +x3: U32, +x4: U32, rd: Array<U32> & U32) -> String:
  (a, x5) = rd
  "cp=" ++ U32.show(x0) ++ " xor=" ++ U32.show(x1) ++ " muladd=" ++ U32.show(x2) ++ " axset=" ++ U32.show(x3) ++ " scale=" ++ U32.show(x4) ++ " zero=" ++ U32.show(x5)

def r4(+x0: U32, +x1: U32, +x2: U32, +x3: U32, rd: Array<U32> & U32) -> String:
  (a, x4) = rd
  r5(x0, x1, x2, x3, x4, Array.get(U32, a, 5))

def r3(+x0: U32, +x1: U32, +x2: U32, rd: Array<U32> & U32) -> String:
  (a, x3) = rd
  r4(x0, x1, x2, x3, Array.get(U32, a, 4))

def r2(+x0: U32, +x1: U32, rd: Array<U32> & U32) -> String:
  (a, x2) = rd
  r3(x0, x1, x2, Array.get(U32, a, 3))

def r1(+x0: U32, rd: Array<U32> & U32) -> String:
  (a, x1) = rd
  r2(x0, x1, Array.get(U32, a, 2))

def r0(rd: Array<U32> & U32) -> String:
  (a, x0) = rd
  r1(x0, Array.get(U32, a, 1))

def fin(st: Cnt) -> String:
  match st:
    case Cnt{p, cn}:
      r0(Array.get(U32, cn, 0))

def prg(pg: S.Pg) -> String:
  match pg:
    case S.Pg{p, m}:
      match m:
        case S.Pm{l, nrows, npiv, ntr, +nin}:
          "instructions=" ++ U32.show(nin) ++ " " ++ fin(loop(U32.to_nat(nin), 0, Cnt{p, Array.new(U32, 3n, 0)}))

def go(m: Maybe<&2, S.Plan>) -> IO(Unit):
  match m:
    case None{}:
      IO.print("None")
    case Some{pl}:
      IO.print(prg(S.Solver.prog(pl)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> rest:
      go(Q.Codec.encoder_plan(rd(ks, 1000)))
    case _:
      go(Q.Codec.encoder_plan(1000))

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)

