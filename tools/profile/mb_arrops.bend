# Cost of Array.get / Array.set: Array<U32> versus an Array of boxed Data elements (what solver.bend's Array<Rw>/Array<List>/Array<VR> are).
#   bend tools/profile/mb_arrops.bend -o build/mb_arrops ; ./build/mb_arrops --threads 1 -- <log2 slots> <ops> <mode>
# mode 0: U32 get+set  1: U32 get only  2: boxed (List<U32>) get+set  3: boxed get only
import Base

type Ac is Type:
  Ac{a: Array<U32>, s: U32}

def u.f(+i: U32, +s: U32, r: Array<U32> & U32) -> Ac:
  (a, +x) = r
  Ac{a[i] <- U32.add(x, 1), U32.add(s, x)}

def u.step(+i: U32, ac: Ac) -> Ac:
  Ac{a, s} = ac
  u.f(i, s, Array.get(U32, a, i))

def u.loop(+n: Nat, +i: U32, +mask: U32, ac: Ac) -> Ac:
  match n:
    case 0n:
      ac
    case 1n+q:
      u.loop(q, U32.and((i * 1103515245 + 12345 : U32), mask), mask, u.step(i, ac))

def ug.f(+i: U32, +s: U32, r: Array<U32> & U32) -> Ac:
  (a, +x) = r
  Ac{a, U32.add(s, x)}

def ug.step(+i: U32, ac: Ac) -> Ac:
  Ac{a, s} = ac
  ug.f(i, s, Array.get(U32, a, i))

def ug.loop(+n: Nat, +i: U32, +mask: U32, ac: Ac) -> Ac:
  match n:
    case 0n:
      ac
    case 1n+q:
      ug.loop(q, U32.and((i * 1103515245 + 12345 : U32), mask), mask, ug.step(i, ac))

type Bc is Type:
  Bc{a: Array<List<&2, U32>>, s: U32}

def hd(xs: List<&2, U32>) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{h, t}:
      h

def b.f(+i: U32, +s: U32, r: Array<List<&2, U32>> & List<&2, U32>) -> Bc:
  (a, +x) = r
  Bc{Array.set(List<&2, U32>, a, i, (U32.add(s, 1) <> Nil{})), U32.add(s, hd(x))}

def b.step(+i: U32, bc: Bc) -> Bc:
  Bc{a, s} = bc
  b.f(i, s, Array.get(List<&2, U32>, a, i))

def b.loop(+n: Nat, +i: U32, +mask: U32, bc: Bc) -> Bc:
  match n:
    case 0n:
      bc
    case 1n+q:
      b.loop(q, U32.and((i * 1103515245 + 12345 : U32), mask), mask, b.step(i, bc))

def bg.f(+i: U32, +s: U32, r: Array<List<&2, U32>> & List<&2, U32>) -> Bc:
  (a, +x) = r
  Bc{a, U32.add(s, hd(x))}

def bg.step(+i: U32, bc: Bc) -> Bc:
  Bc{a, s} = bc
  bg.f(i, s, Array.get(List<&2, U32>, a, i))

def bg.loop(+n: Nat, +i: U32, +mask: U32, bc: Bc) -> Bc:
  match n:
    case 0n:
      bc
    case 1n+q:
      bg.loop(q, U32.and((i * 1103515245 + 12345 : U32), mask), mask, bg.step(i, bc))

def fu(ac: Ac) -> U32:
  match ac:
    case Ac{a, s}:
      s

def fb(bc: Bc) -> U32:
  match bc:
    case Bc{a, s}:
      s

def pick(+mode: U32, +lg: Nat, +n: Nat, +mask: U32) -> U32:
  match mode:
    case 0:
      fu(u.loop(n, 1, mask, Ac{Array.new(U32, lg, 0), 0}))
    case 1:
      fu(ug.loop(n, 1, mask, Ac{Array.new(U32, lg, 0), 0}))
    case 2:
      fb(b.loop(n, 1, mask, Bc{Array.new(List<&2, U32>, lg, Nil{}), 0}))
    case _:
      fb(bg.loop(n, 1, mask, Bc{Array.new(List<&2, U32>, lg, Nil{}), 0}))

def run(+lg: Nat, +n: Nat, +mode: U32) -> IO(Unit):
  +mask = (U32.shln(1, lg) - 1 : U32)
  do IO<Unit>:
    t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(pick(mode, lg, n, mask)))
    t1 : Nat <- IO.now()
    IO.print("RESULT arrops lg=" ++ Nat.show(lg) ++ " ops=" ++ Nat.show(n) ++ " mode=" ++ U32.show(mode) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> c <> rest:
      run(U32.to_nat(rd(a, 16)), U32.to_nat(rd(b, 1000000)), rd(c, 0))
    case _:
      run(16n, 1000000n, 0)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
