# Micro-benchmark: Vec.xor / Vec.muladd / Vec.scale chains on one dst vector (hot in cache).
#   bend tools/profile/mb_vec.bend -o build/mb_vec ; ./build/mb_vec [--threads N] -- <words> <ops> <mode>
# mode 0 = xor, 1 = muladd (c varies, never 0/1), 2 = scale-chain-ish (muladd of src with c fixed 3)
import Base
import ../../src/gf256.bend as G

def words(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      words(p, (x * 1664525 + 1013904223 : U32), x <> acc)

def chain(n: Nat, +mode: U32, +c: U32, acc: G.Vec, +src: G.Vec) -> G.Vec:
  match n:
    case 0n:
      acc
    case 1n+p:
      match mode:
        case 0:
          chain(p, mode, c, G.Vec.xor(acc, src), src)
        case _:
          chain(p, mode, (c + 1 : U32), G.Vec.muladd(((c .&. 255 : U32) .|. 2 : U32), acc, src), src)

def sum(v: G.Vec) -> U32:
  match v:
    case G.VNode{l, r}:
      (sum(l) + sum(r) : U32)
    case G.VWord{w}:
      w
    case G.VNil{}:
      0

def run(+w: U32, +m: U32, +mode: U32) -> IO(Unit):
  +a = G.Vec.from_list(words(U32.to_nat(w), 7, Nil{}))
  +b = G.Vec.from_list(words(U32.to_nat(w), 99, Nil{}))
  do IO<Unit>:
    IO.print("warm " ++ U32.show((sum(a) + sum(b) : U32)))
    t0 : Nat <- IO.now()
    IO.print("sum=" ++ U32.show(sum(chain(U32.to_nat(m), mode, 3, a, b))))
    t1 : Nat <- IO.now()
    IO.print("RESULT words=" ++ U32.show(w) ++ " ops=" ++ U32.show(m) ++ " mode=" ++ U32.show(mode) ++ " ms=" ++ Nat.show((t1 - t0 : Nat)))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case p <> a <> b <> c <> rest:
      run(rd(a, 64), rd(b, 1000), rd(c, 1))
    case _:
      run(64, 1000, 1)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
