# Phase breakdown of Solver (scratch/profiling): runs the solver pipeline cut after stage S and times it.
#   (needs the Solver.cut harness appended to a COPY of src/solver.bend: see tools/profile/README in docs/profile.md)
#   bend tools/profile/phases.bend -o build/phases ; ./build/phases [--threads N] -- <K> <T octets> <stage>
#   stage 0 = row build only, 1 = +normalise/index (init), 2 = +phase1 loop, 3 = +log replay (mat_pivs), 4 = +leftover/dense rows,
#   5 = +tail Gauss-Jordan, 6 = full solve (phase 3 included, Solver.solve_p).  Cumulative; phase time = difference.
import Base
import ../../src/gf256.bend as G
import ../../src/types.bend as Y
import ../../src/tables.bend as T
import ../../src/rfc_funcs.bend as R
import ../../src/constraints.bend as C
import ../../src/solver.bend as S

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
          nterms(rest, (acc + U32.from_nat(List.length(&2, Y.Term, cols)) + vsum(rhs, 0) : U32))

def cut(stage: U32, +sp: T.SP, rows: List<&2, Y.Row>) -> U32:
  match stage:
    case 6:
      msum(S.Solver.solve_p(R.L(sp), R.P(sp), rows))
    case _:
      S.Solver.cut((stage - 1 : U32), R.L(sp), R.P(sp), rows)

def timed(+stage: U32, +sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    IO.print("rows built (fresh), check " ++ U32.show(nterms(rows_of(sp, tw, src), 0)))
    +t1 : Nat <- IO.now()
    IO.print("check " ++ U32.show(cut(stage, sp, rows_of(sp, tw, src))))
    +t2 : Nat <- IO.now()
    IO.print("PHASES K'=" ++ U32.show(R.Kp(sp)) ++ " T=" ++ U32.show((4 * tw : U32)) ++ " stage=" ++ U32.show(stage) ++ " rows_ms=" ++ Nat.show((t1 - t0 : Nat)) ++ " cut_ms=" ++ Nat.show((t2 - t1 - (t1 - t0) : Nat)) ++ " cut_incl_rows_ms=" ++ Nat.show((t2 - t1 : Nat)))

def go(+k: U32, +stage: U32, +sp: T.SP, +tw: U32, +src: List<&2, G.Vec>) -> IO(Unit):
  do IO<Unit>:
    IO.print("K=" ++ U32.show(k) ++ " L=" ++ U32.show(R.L(sp)) ++ " P=" ++ U32.show(R.P(sp)))
    timed(stage, sp, tw, src)

def run(+k: U32, +stage: U32, +tw: U32) -> IO(Unit):
  go(k, stage, sp_of(k), tw, syms(U32.to_nat(k), tw, (k * 65536 + 16 : U32), Nil{}))

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> ks <> ts <> ss <> rest:
      run(rd(ks, 1000), rd(ss, 6), U32.shrn((rd(ts, 16) + 3 : U32), 2n))
    case _:
      run(1000, 6, 4)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
