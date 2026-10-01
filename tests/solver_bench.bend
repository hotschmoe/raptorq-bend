# Solver benchmark / integration test on REAL RaptorQ systems (src/constraints.bend).
# Usage:  bend tests/solver_bench.bend -- <K> <mode>
#   mode 0 = Solver.solve_p (inactivation), 1 = Solver.solve_dense (oracle), 2 = only build the rows
# Builds the K'x(S+H+K') system with LCG-random source symbols (T = 16 octets), solves it, then checks
# C by re-encoding every source ISI (Constraints.encode must give back the source symbol).
# Prints "OK ..." and exits 0, or dies with exit code 1.
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/tables.bend as T
import ../src/rfc_funcs.bend as R
import ../src/constraints.bend as C
import ../src/solver.bend as S

def TW() -> U32:
  4   # words per symbol (T = 16 octets)

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def words(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      words(p, lcg(x), (x .^. U32.shrn(x, 16n) : U32) <> acc)

def next_x(n: Nat, +x: U32) -> U32:
  match n:
    case 0n:
      x
    case 1n+p:
      next_x(p, lcg(x))

# k symbols of TW words each
def syms(n: Nat, +x: U32, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      List.reverse(&2, G.Vec, acc)
    case 1n+p:
      syms(p, next_x(U32.to_nat(TW()), x), G.Vec.from_list(words(U32.to_nat(TW()), x, Nil{})) <> acc)

def sp_of.go(m: Maybe<&2, T.SP>) -> T.SP:
  match m:
    case Some{sp}:
      sp
    case None{}:
      T.SP{0, 0, 0, 0, 0, 0}

def sp_of(+k: U32) -> T.SP:
  sp_of.go(R.params(k))

def band(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

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

def vbad(b: Bool) -> U32:
  match b:
    case True{}:
      0
    case False{}:
      1

# every source ISI re-encodes to its source symbol: returns the number of mismatches
def verify(src: List<&2, G.Vec>, +sp: T.SP, +tr: C.ITree, +i: U32, bad: U32) -> U32:
  match src:
    case Nil{}:
      bad
    case s <> rest:
      verify(rest, sp, tr, (i + 1 : U32), (bad + vbad(veq(s, C.encode_idx(sp, tr, i))) : U32))

def rows_of(+sp: T.SP, +src: List<&2, G.Vec>) -> List<&2, Y.Row>:
  List.append(&2, Y.Row, C.fixed(sp, (4 * TW() : U32)), C.source_rows(sp, src))

def solve(mode: U32, +sp: T.SP, +src: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match mode:
    case 0:
      S.Solver.solve_p(R.L(sp), R.P(sp), rows_of(sp, src))
    case _:
      S.Solver.solve_dense(R.L(sp), rows_of(sp, src))

def report2(bad: U32) -> IO(Unit):
  match bad:
    case 0:
      IO.print("OK: all source symbols re-encode correctly")
    case _:
      IO.die(Unit, 1, "FAIL: mismatching source symbols: " ++ U32.show(bad))

def report(r: Maybe<&2, List<&2, G.Vec>>, +src: List<&2, G.Vec>, +sp: T.SP) -> IO(Unit):
  match r:
    case None{}:
      IO.die(Unit, 1, "FAIL: solver returned None")
    case Some{c}:
      report2(verify(src, sp, C.index(c), 0, 0))

def solved_only(r: Maybe<&2, List<&2, G.Vec>>) -> IO(Unit):
  match r:
    case None{}:
      IO.die(Unit, 1, "FAIL: solver returned None")
    case Some{c}:
      IO.print("solved (not verified), symbols: " ++ U32.show(U32.from_nat(List.length(&2, G.Vec, c))))

def go2(mode: U32, +sp: T.SP, +src: List<&2, G.Vec>) -> IO(Unit):
  match mode:
    case 2:
      IO.print("rows built: " ++ U32.show(U32.from_nat(List.length(&2, Y.Row, rows_of(sp, src)))))
    case 3:
      IO.print("inactive columns after phase 1: " ++ U32.show(S.Solver.inactive_count(R.L(sp), R.P(sp), rows_of(sp, src))))
    case 4:
      solved_only(solve(0, sp, src))
    case _:
      report(solve(mode, sp, src), src, sp)

def go(+k: U32, +mode: U32, +sp: T.SP, +src: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    IO.print("K=" ++ U32.show(k) ++ " K'=" ++ U32.show(R.Kp(sp)) ++ " L=" ++ U32.show(R.L(sp)) ++ " P=" ++ U32.show(R.P(sp)) ++ " mode=" ++ U32.show(mode))
    go2(mode, sp, src)

def run(+k: U32, mode: U32) -> IO(Unit):
  go(k, mode, sp_of(k), syms(U32.to_nat(k), (k * 65536 + 16 : U32), Nil{}))

def arg_u32.go(m: Maybe<String>, d: U32) -> U32:
  match m:
    case None{}:
      d
    case Some{s}:
      Maybe.default(&2, U32, U32.read(s), d)

def rd(s: String, d: U32) -> U32:
  arg_u32.go(Some{s}, d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ms <> rest:
      run(rd(ks, 10), rd(ms, 0))
    case prog <> ks <> Nil{}:
      run(rd(ks, 10), 0)
    case _:
      run(10, 0)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
