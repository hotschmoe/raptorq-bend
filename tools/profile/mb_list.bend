# Proxy for the solver's sparse bookkeeping (phase 1 / row normalisation work on lists of Term{col,coef}): map over a cons list
# of N 2-field records (alloc one cons + one record per element, free the old), R rounds, then a checksum.
#   bend tools/profile/mb_list.bend -o build/mb_list ; ./build/mb_list --threads 1 -- <N> <rounds>
import Base

type Tm is Data:
  Tm{col: U32, coef: U32}

def mk(+n: Nat, +x: U32, acc: List<&2, Tm>) -> List<&2, Tm>:
  match n:
    case 0n:
      acc
    case 1n+q:
      mk(q, (x * 1664525 + 1013904223 : U32), Tm{x, U32.and(x, 255)} <> acc)

def mp(xs: List<&2, Tm>, acc: List<&2, Tm>) -> List<&2, Tm>:
  match xs:
    case Nil{}:
      List.reverse(&2, Tm, acc)
    case Con{h, t}:
      match h:
        case Tm{c, +f}:
          mp(t, Tm{(c + f : U32), f} <> acc)

def rounds(+r: Nat, xs: List<&2, Tm>) -> List<&2, Tm>:
  match r:
    case 0n:
      xs
    case 1n+q:
      rounds(q, mp(xs, Nil{}))

def sm(xs: List<&2, Tm>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      match h:
        case Tm{c, f}:
          sm(t, (acc * 31 + c + f : U32))

def run(+n: Nat, +r: Nat) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(sm(rounds(r, mk(n, 7, Nil{})), 0)))
    t1 : Nat <- IO.now()
    IO.print("RESULT list n=" ++ Nat.show(n) ++ " rounds=" ++ Nat.show(r) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> rest:
      run(U32.to_nat(rd(a, 1000)), U32.to_nat(rd(b, 1000)))
    case _:
      run(1000n, 1000n)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
