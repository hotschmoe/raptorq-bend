# Solver benchmark / integration test on REAL RaptorQ systems (src/constraints.bend).
# Usage:  bend tests/solver_bench.bend -o sb;  ./sb [--threads N] -- <K> <mode> [<T octets, default 16>]
#   mode 0 = Solver.solve_p (inactivation) + verify, 1 = Solver.solve_dense (oracle) + verify, 2 = only build the rows,
#   3 = print the inactive-set size, 4 = solve only (not verified), 5 = timed inactivation solve, 6 = timed dense oracle: prints "rows ms", "solve ms" (rows built twice,
#   the second build is subtracted) and a checksum of C.
# Builds the K'x(S+H+K') system with LCG-random source symbols (T octets), solves it, then (modes 0/1) checks
# C by re-encoding every source ISI (Constraints.encode must give back the source symbol).
# Prints "OK ..." and exits 0, or dies with exit code 1.
import Base
import ../src/gf256.bend as G
import ../src/types.bend as Y
import ../src/tables.bend as T
import ../src/rfc_funcs.bend as R
import ../src/constraints.bend as C
import ../src/solver.bend as S

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
def syms(n: Nat, +tw: U32, +x: U32, acc: List<&2, G.Vec>) -> List<&2, G.Vec>:
  match n:
    case 0n:
      List.reverse(&2, G.Vec, acc)
    case 1n+p:
      syms(p, tw, next_x(U32.to_nat(tw), x), G.Vec.from_list(words(U32.to_nat(tw), x, Nil{})) <> acc)

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

def rows_of(+sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> List<&2, Y.Row>:
  List.append(&2, Y.Row, C.fixed(sp, (4 * tw : U32)), C.source_rows(sp, src))

def solve(mode: U32, +sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> Maybe<&2, List<&2, G.Vec>>:
  match mode:
    case 1:
      S.Solver.solve_dense(R.L(sp), rows_of(sp, tw, src))
    case _:
      S.Solver.solve_p(R.L(sp), R.P(sp), rows_of(sp, tw, src))

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

# xor of every word of every symbol: forces the whole result
def vsum(v: G.Vec, acc: U32) -> U32:
  match v:
    case G.VNode{l, r}:
      vsum(r, vsum(l, acc))
    case G.VWord{w}:
      (acc .^. (w * 31 + 7 : U32) : U32)
    case G.VNil{}:
      acc

def csum(cs: List<&2, G.Vec>, acc: U32) -> U32:
  match cs:
    case Nil{}:
      acc
    case h <> t:
      csum(t, vsum(h, (acc * 3 + 1 : U32)))

def msum(r: Maybe<&2, List<&2, G.Vec>>) -> U32:
  match r:
    case None{}:
      0
    case Some{c}:
      csum(c, 1)

def nterms(rs: List<&2, Y.Row>, acc: U32) -> U32:
  match rs:
    case Nil{}:
      acc
    case r <> rest:
      match r:
        case Y.Row{cols, rhs}:
          nterms(rest, (acc + U32.from_nat(List.length(&2, Y.Term, cols)) : U32))

def timed(mode: U32, +sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    IO.print("rows built, terms: " ++ U32.show(nterms(rows_of(sp, tw, src), 0)))
    +t1 : Nat <- IO.now()
    IO.print("checksum of C: " ++ U32.show(msum(solve(mode, sp, tw, src))))
    +t2 : Nat <- IO.now()
    IO.print("T=" ++ U32.show((4 * tw : U32)) ++ " octets: rows ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " solve ms=" ++ Nat.show((t2 - t1 - (t1 - t0) : Nat)) ++ " (total with 2nd row build " ++ Nat.show((t2 - t1 : Nat)) ++ ")")

def go2(mode: U32, +sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> IO(Unit):
  match mode:
    case 2:
      IO.print("rows built: " ++ U32.show(U32.from_nat(List.length(&2, Y.Row, rows_of(sp, tw, src)))))
    case 3:
      IO.print("inactive columns after phase 1: " ++ U32.show(S.Solver.inactive_count(R.L(sp), R.P(sp), rows_of(sp, tw, src))))
    case 4:
      solved_only(solve(0, sp, tw, src))
    case 5:
      timed(0, sp, tw, src)
    case 6:
      timed(1, sp, tw, src)
    case _:
      report(solve(mode, sp, tw, src), src, sp)

def go(+k: U32, +mode: U32, +sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    IO.print("K=" ++ U32.show(k) ++ " K'=" ++ U32.show(R.Kp(sp)) ++ " L=" ++ U32.show(R.L(sp)) ++ " P=" ++ U32.show(R.P(sp)) ++ " mode=" ++ U32.show(mode))
    go2(mode, sp, tw, src)

def run(+k: U32, mode: U32, +tw: U32) -> IO(Unit):
  go(k, mode, sp_of(k), tw, syms(U32.to_nat(k), tw, (k * 65536 + 16 : U32), Nil{}))

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
    case prog <> ks <> ms <> ts <> rest:
      run(rd(ks, 10), rd(ms, 0), U32.shrn((rd(ts, 16) + 3 : U32), 2n))
    case prog <> ks <> ms <> Nil{}:
      run(rd(ks, 10), rd(ms, 0), 4)
    case prog <> ks <> Nil{}:
      run(rd(ks, 10), 0, 4)
    case _:
      run(10, 0, 4)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
