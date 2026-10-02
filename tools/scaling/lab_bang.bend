# Scaling lab WITH bang variants (modes 20..25 = modes 0, 1, 3, 2, 5, 6 with the entry call `f!(..)`); same as lab.bend otherwise.  Build with clang 19
# (docs/scaling.md section H) and run with --gpu off.  Because the program contains `!`, the whole binary runs without the single-thread `seq` fast path.
# Scaling lab (docs/scaling.md): what pure Bend scales on this machine.
#   bend tools/scaling/lab.bend -o build/scaling/lab        (system clang first in PATH, see CLAUDE.md)
#   ./build/scaling/lab --threads N -- <mode> <D> <w> <reps> <extra>
# Prints  LAB mode=.. D=.. w=.. reps=.. extra=.. threads=.. ms=.. chk=..
# Modes (2^D leaves of 2^w words, `reps` read-modify-write passes per leaf = the work knob):
#   0 tree      balanced fork tree, tail-recursive leaf kernel over its OWN freshly allocated Array<U32>
#   1 seqforks  `extra` fork trees reached one after the other from sequential code (each tree as mode 0), tail loop
#   2 wrapped   ONE fork tree whose leaves each run `extra` sequential leaf kernels (the same total work as mode 1 with one region)
#   3 nontail   as mode 0 but the leaf kernel is a NON-tail recursion (sum of a hash chain, no array), 2^w steps per rep
#   4 tailnum   as mode 3 with a tail-recursive accumulator loop (control for 3)
#   5 split     ONE shared array of 2^D * 2^w words is cut by ANode matches (halves) into 2^D slices processed by a fork tree and
#               re-joined with ANode{} (zero copy)
#   6 chunks    the input as a balanced tree of leaf arrays (type At) built inside the tasks; tasks get a subtree and return it
#   7 serial    2^D leaf kernels one after the other (no fork at all): the per-leaf cost reference
#   9 treezip   NO fork anywhere: sequential non-tail tree walk that allocates nodes (the Vec.xor shape), `reps` zips of 2^w-leaf trees
#  10 treezipf  as 9 but the walk def also contains a (never taken) fork branch, like G.Vec.xor.go
#  11 treezipg  as 10 but the fork-free branch calls a separate fork-free twin def
#  12 shared    repair-generation shape: ONE shared read-only array S of 2^extra symbols (2^w words each) handed to the leaves of a fork
#               tree with Array.fork; each leaf XORs `reps` pseudo-random symbols of S into its own freshly allocated output symbol
#               (only the parallel part is timed)
#  20..25      the entry call banged `f!(..)`: 20 = 0, 21 = 1, 22 = 3, 23 = 2, 24 = 5, 25 = 6 (clang 19, run with --gpu off)
#  15 sharedclone as 12 but the handles come from Array.clone (a copy per node of the tree; no unsafe def)
#  13 sharedlist a Data list (the shape of a Solver.Plan, 2^w elements) walked `reps` times by every leaf of a fork tree
#  14 ownlist    as 13 but every leaf builds its own copy of the list
import Base

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

# ---- leaf kernel: tail loop, in-place read-modify-write ------------------------------------------------------------
def k.f2(+j: U32, +r: U32, rd: Array<U32> & U32) -> Array<U32>:
  (a, y) = rd
  Array.set(U32, a, j, U32.xor(lcg(y), (j + r : U32)))

def k.loop(+n: Nat, +j: U32, +r: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+q:
      k.loop(q, U32.inc(j), r, k.f2(j, r, Array.get(U32, a, j)))

def k.rounds(+rs: Nat, +n: Nat, a: Array<U32>) -> Array<U32>:
  match rs:
    case 0n:
      a
    case 1n+q:
      k.rounds(q, n, k.loop(n, 0, U32.inc(U32.from_nat(q)), a))

def chk.f(r: Array<U32> & U32) -> U32:
  (b, x) = r
  x

def chk(a: Array<U32>) -> U32:
  chk.f(Array.get(U32, a, 0))

def pow2n(+w: Nat) -> Nat:
  Nat.pow(2n, w)

def leaf(+w: Nat, +reps: Nat) -> U32:
  chk(k.rounds(reps, pow2n(w), Array.new(U32, w, 7)))

# ---- 0 tree --------------------------------------------------------------------------------------------------------
def tree(+d: Nat, +w: Nat, +reps: Nat) -> U32:
  match d:
    case 0n:
      leaf(w, reps)
    case 1n+p:
      a b = tree(p, w, reps) tree(p, w, reps)
      (a + b : U32)

# ---- 1 seqforks ----------------------------------------------------------------------------------------------------
def seqforks(+n: Nat, +d: Nat, +w: Nat, +reps: Nat, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+q:
      seqforks(q, d, w, reps, (acc + tree(d, w, reps) : U32))

# ---- 2 wrapped -----------------------------------------------------------------------------------------------------
def seqleaf(+n: Nat, +w: Nat, +reps: Nat, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+q:
      seqleaf(q, w, reps, (acc + leaf(w, reps) : U32))

def wrapped(+d: Nat, +n: Nat, +w: Nat, +reps: Nat) -> U32:
  match d:
    case 0n:
      seqleaf(n, w, reps, 0)
    case 1n+p:
      a b = wrapped(p, n, w, reps) wrapped(p, n, w, reps)
      (a + b : U32)

# ---- 3 nontail / 4 tailnum -----------------------------------------------------------------------------------------
def nt(+n: Nat, +x: U32) -> U32:
  match n:
    case 0n:
      x
    case 1n+q:
      (lcg(x) .^. nt(q, lcg(x)) : U32)

def tn(+n: Nat, +x: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      (acc + x : U32)
    case 1n+q:
      tn(q, lcg(x), (acc + lcg(x) : U32))

def ntrep(+rs: Nat, +n: Nat, +acc: U32) -> U32:
  match rs:
    case 0n:
      acc
    case 1n+q:
      ntrep(q, n, (acc + nt(n, U32.from_nat(q)) : U32))

def tnrep(+rs: Nat, +n: Nat, +acc: U32) -> U32:
  match rs:
    case 0n:
      acc
    case 1n+q:
      tnrep(q, n, (acc + tn(n, U32.from_nat(q), 0) : U32))

def tree3(+d: Nat, +w: Nat, +reps: Nat) -> U32:
  match d:
    case 0n:
      ntrep(reps, pow2n(w), 0)
    case 1n+p:
      a b = tree3(p, w, reps) tree3(p, w, reps)
      (a + b : U32)

def tree4(+d: Nat, +w: Nat, +reps: Nat) -> U32:
  match d:
    case 0n:
      tnrep(reps, pow2n(w), 0)
    case 1n+p:
      a b = tree4(p, w, reps) tree4(p, w, reps)
      (a + b : U32)

# ---- 7 serial ------------------------------------------------------------------------------------------------------
def serial(+n: Nat, +w: Nat, +reps: Nat, +acc: U32) -> U32:
  seqleaf(n, w, reps, acc)

# ---- 5 split: cut ONE array by ANode matches -----------------------------------------------------------------------
type Pr is Type:
  Pr{l: Array<U32>, r: Array<U32>}

# the slice kernel on a sub-array (indices relative to the sub-array)
def sl.rounds(+rs: Nat, +n: Nat, a: Array<U32>) -> Array<U32>:
  k.rounds(rs, n, a)

def split.join(l: Array<U32>, r: Array<U32>) -> Array<U32>:
  ANode{l, r}

def split.go(+d: Nat, +w: Nat, +reps: Nat, a: Array<U32>) -> Array<U32>:
  match d:
    case 0n:
      sl.rounds(reps, pow2n(w), a)
    case 1n+p:
      match a:
        case ALeaf{x}:
          ALeaf{x}
        case ANode{l, r}:
          x y = split.go(p, w, reps, l) split.go(p, w, reps, r)
          ANode{x, y}

def split.run(+d: Nat, +w: Nat, +reps: Nat) -> U32:
  chk(split.go(d, w, reps, Array.new(U32, (d + w : Nat), 7)))

# ---- 6 chunks: tree of leaf arrays -----------------------------------------------------------------------------------
type At is Type:
  At{a: Array<U32>}
  An{l: At, r: At}

def at.build(+d: Nat, +w: Nat) -> At:
  match d:
    case 0n:
      At{Array.new(U32, w, 7)}
    case 1n+p:
      l r = at.build(p, w) at.build(p, w)
      An{l, r}

def at.work(+reps: Nat, +w: Nat, t: At) -> At:
  match t:
    case At{a}:
      At{k.rounds(reps, pow2n(w), a)}
    case An{l, r}:
      x y = at.work(reps, w, l) at.work(reps, w, r)
      An{x, y}

def at.chk(t: At) -> U32:
  match t:
    case At{a}:
      chk(a)
    case An{l, r}:
      (at.chk(l) .^. at.chk(r) : U32)

def chunks(+d: Nat, +w: Nat, +reps: Nat) -> U32:
  at.chk(at.work(reps, w, at.build(d, w)))

# ---- 9 treezip: sequential non-tail tree walk that allocates nodes (the `Vec.xor` shape), no fork at all --------------
type Tr is Data:
  Lf{x: U32}
  Nd{l: Tr, r: Tr}

def tr.build(+d: Nat, +x: U32) -> Tr:
  match d:
    case 0n:
      Lf{x}
    case 1n+p:
      Nd{tr.build(p, lcg(x)), tr.build(p, (x + 1 : U32))}

def tr.zip(a: Tr, b: Tr) -> Tr:
  match a b:
    case Lf{x} Lf{y}:
      Lf{U32.xor(x, y)}
    case Nd{al, ar} Nd{bl, br}:
      Nd{tr.zip(al, bl), tr.zip(ar, br)}
    case _ _:
      Lf{0}

def tr.sum(t: Tr, +acc: U32) -> U32:
  match t:
    case Lf{x}:
      (acc + x : U32)
    case Nd{l, r}:
      tr.sum(r, tr.sum(l, acc))

def tr.chain(+n: Nat, a: Tr, +b: Tr) -> Tr:
  match n:
    case 0n:
      a
    case 1n+q:
      tr.chain(q, tr.zip(a, b), b)

# leaves of 2^w words per tree (w = depth), `reps` zips
def treezip(+w: Nat, +reps: Nat) -> U32:
  tr.sum(tr.chain(reps, tr.build(w, 1), tr.build(w, 2)), 0)

# mode 10: same walk, but the def also contains a fork branch (fk > 0), which is never taken (fk = 0): does the mere presence of a
# parallel `let` in the def slow its fork-free branch at --threads > 1?  mode 11: the fork-free branch is a separate twin def.
def tr.zipf(+fk: Nat, a: Tr, b: Tr) -> Tr:
  match fk:
    case 0n:
      match a b:
        case Lf{x} Lf{y}:
          Lf{U32.xor(x, y)}
        case Nd{al, ar} Nd{bl, br}:
          Nd{tr.zipf(fk, al, bl), tr.zipf(fk, ar, br)}
        case _ _:
          Lf{0}
    case 1n+q:
      match a b:
        case Lf{x} Lf{y}:
          Lf{U32.xor(x, y)}
        case Nd{al, ar} Nd{bl, br}:
          l r = tr.zipf(q, al, bl) tr.zipf(q, ar, br)
          Nd{l, r}
        case _ _:
          Lf{0}

def tr.zipg(+fk: Nat, a: Tr, b: Tr) -> Tr:
  match fk:
    case 0n:
      tr.zip(a, b)
    case 1n+q:
      match a b:
        case Lf{x} Lf{y}:
          Lf{U32.xor(x, y)}
        case Nd{al, ar} Nd{bl, br}:
          l r = tr.zipg(q, al, bl) tr.zipg(q, ar, br)
          Nd{l, r}
        case _ _:
          Lf{0}

def tr.chain10(+n: Nat, a: Tr, +b: Tr) -> Tr:
  match n:
    case 0n:
      a
    case 1n+q:
      tr.chain10(q, tr.zipf(0n, a, b), b)

def tr.chain11(+n: Nat, a: Tr, +b: Tr) -> Tr:
  match n:
    case 0n:
      a
    case 1n+q:
      tr.chain11(q, tr.zipg(0n, a, b), b)

def treezipf(+m: U32, +w: Nat, +reps: Nat) -> U32:
  match m:
    case 10:
      tr.sum(tr.chain10(reps, tr.build(w, 1), tr.build(w, 2)), 0)
    case _:
      tr.sum(tr.chain11(reps, tr.build(w, 1), tr.build(w, 2)), 0)

# ---- 12 shared: repair-generation shape.  S = 2^sw words holding nsym symbols of 2^w words.  A balanced fork tree of 2^D leaves;
# leaf i allocates its own output symbol and XORs `reps` symbols of S (pseudo-random indices) into it, returns a checksum.  S reaches
# the leaves through Array.fork (O(1), two handles of one array, read-only use). ---------------------------------------------
type Sp is Type:
  Sp{o: Array<U32>, s: Array<U32>}

def sh.f2(+j: U32, s: Array<U32>, ro: Array<U32> & U32, +x: U32) -> Sp:
  (o, y) = ro
  Sp{Array.set(U32, o, j, U32.xor(y, x)), s}

def sh.f1(+j: U32, o: Array<U32>, rs: Array<U32> & U32) -> Sp:
  (s, x) = rs
  sh.f2(j, s, Array.get(U32, o, j), x)

def sh.step(+j: U32, +sb: U32, p: Sp) -> Sp:
  match p:
    case Sp{o, s}:
      sh.f1(j, o, Array.get(U32, s, (sb + j : U32)))

def sh.xor(+n: Nat, +j: U32, +sb: U32, p: Sp) -> Sp:
  match n:
    case 0n:
      p
    case 1n+q:
      sh.xor(q, U32.inc(j), sb, sh.step(j, sb, p))

def sh.reps(+reps: Nat, +n: Nat, +nu: U32, +nsym: U32, +x: U32, p: Sp) -> Sp:
  match reps:
    case 0n:
      p
    case 1n+q:
      sh.reps(q, n, nu, nsym, lcg(x), sh.xor(n, 0, (U32.and(lcg(x), (nsym - 1 : U32)) * nu : U32), p))

def sh.out(p: Sp) -> U32:
  match p:
    case Sp{o, s}:
      chk(o)

def sh.leaf(+w: Nat, +nsym: U32, +reps: Nat, +x: U32, s: Array<U32>) -> U32:
  sh.out(sh.reps(reps, pow2n(w), U32.from_nat(pow2n(w)), nsym, x, Sp{Array.new(U32, w, 0), s}))

def sh.tree(+d: Nat, +w: Nat, +nsym: U32, +reps: Nat, +x: U32, r: Array<U32> & Array<U32>) -> U32:
  match d:
    case 0n:
      (s1, s2) = r
      sh.leaf(w, nsym, reps, x, s1)
    case 1n+p:
      (s1, s2) = r
      a b = sh.tree(p, w, nsym, reps, lcg(x), Array.fork(U32, s1)) sh.tree(p, w, nsym, reps, (x + 1 : U32), Array.fork(U32, s2))
      (a + b : U32)

def sh.treec(+d: Nat, +w: Nat, +nsym: U32, +reps: Nat, +x: U32, r: Array<U32> & Array<U32>) -> U32:
  match d:
    case 0n:
      (s1, s2) = r
      sh.leaf(w, nsym, reps, x, s1)
    case 1n+p:
      (s1, s2) = r
      a b = sh.treec(p, w, nsym, reps, lcg(x), Array.clone(U32, s1)) sh.treec(p, w, nsym, reps, (x + 1 : U32), Array.clone(U32, s2))
      (a + b : U32)

# S: nsym symbols of 2^w words, filled by an LCG
def sh.fill(+n: Nat, +k: U32, +x: U32, a: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+p:
      sh.fill(p, U32.inc(k), lcg(x), a[k] <- x)

def sh.runc(+d: Nat, +w: Nat, +reps: Nat, +ns: Nat) -> U32:
  sh.treec(d, w, U32.from_nat(pow2n(ns)), reps, 1, Array.clone(U32, sh.fill(pow2n((ns + w : Nat)), 0, 3, Array.new(U32, (ns + w : Nat), 0))))

def sh.run(+d: Nat, +w: Nat, +reps: Nat, +ns: Nat) -> U32:
  sh.tree(d, w, U32.from_nat(pow2n(ns)), reps, 1, Array.fork(U32, sh.fill(pow2n((ns + w : Nat)), 0, 3, Array.new(U32, (ns + w : Nat), 0))))

# ---- 13 sharedlist: a Data list (the shape of a Solver.Plan) read by every leaf of a fork tree; 14: every leaf builds its own copy ----
def sl.build(+n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      sl.build(p, lcg(x), x <> acc)

def sl.sum(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      sl.sum(t, (acc + h : U32))

def sl.reps(+r: Nat, +xs: List<&2, U32>, +acc: U32) -> U32:
  match r:
    case 0n:
      acc
    case 1n+q:
      sl.reps(q, xs, (acc + sl.sum(xs, 0) : U32))

def sl.tree(+d: Nat, +reps: Nat, +xs: List<&2, U32>) -> U32:
  match d:
    case 0n:
      sl.reps(reps, xs, 0)
    case 1n+p:
      a b = sl.tree(p, reps, xs) sl.tree(p, reps, xs)
      (a + b : U32)

def sl.tree2(+d: Nat, +reps: Nat, +w: Nat) -> U32:
  match d:
    case 0n:
      sl.reps(reps, sl.build(Nat.pow(2n, w), 1, []), 0)
    case 1n+p:
      a b = sl.tree2(p, reps, w) sl.tree2(p, reps, w)
      (a + b : U32)

# ---- bang (`f!(..)`) variants: modes 20..24 are 0, 1, 3, 2, 5 with the entry call banged (needs clang 19: docs/scaling.md section H) ----
def seqforks.b(+n: Nat, +d: Nat, +w: Nat, +reps: Nat, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+q:
      seqforks.b(q, d, w, reps, (acc + tree!(d, w, reps) : U32))

# ---- driver --------------------------------------------------------------------------------------------------------
def run(+mode: U32, +d: Nat, +w: Nat, +reps: Nat, +extra: Nat) -> U32:
  match mode:
    case 0:
      tree(d, w, reps)
    case 1:
      seqforks(extra, d, w, reps, 0)
    case 2:
      wrapped(d, extra, w, reps)
    case 3:
      tree3(d, w, reps)
    case 4:
      tree4(d, w, reps)
    case 5:
      split.run(d, w, reps)
    case 6:
      chunks(d, w, reps)
    case 9:
      treezip(w, reps)
    case 13:
      sl.tree(d, reps, sl.build(pow2n(w), 1, []))
    case 14:
      sl.tree2(d, reps, w)
    case 12:
      sh.run(d, w, reps, extra)
    case 10:
      treezipf(10, w, reps)
    case 11:
      treezipf(11, w, reps)
    case 20:
      tree!(d, w, reps)
    case 21:
      seqforks.b(extra, d, w, reps, 0)
    case 22:
      tree3!(d, w, reps)
    case 23:
      wrapped!(d, extra, w, reps)
    case 24:
      split.run!(d, w, reps)
    case 25:
      chunks!(d, w, reps)
    case 7:
      serial(pow2n(d), w, reps, 0)
    case _:
      0

def report(+mode: U32, +d: Nat, +w: Nat, +reps: Nat, +extra: Nat, +thr: U32, +ms: Nat, +c: U32) -> IO(Unit):
  IO.print("LAB mode=" ++ U32.show(mode) ++ " D=" ++ Nat.show(d) ++ " w=" ++ Nat.show(w) ++ " reps=" ++ Nat.show(reps) ++ " extra=" ++ Nat.show(extra) ++ " threads=" ++ U32.show(thr) ++ " ms=" ++ Nat.show(ms) ++ " chk=" ++ U32.show(c))

# mode 12 times only the parallel part: S is built (and forced) before the clock starts
def go12(+d: Nat, +w: Nat, +reps: Nat, +ns: Nat) -> IO(Unit):
  do IO<Unit>:
    +thr : U32 <- IO.thread_count()
    s : Array<U32> <- IO.pure(Array<U32>, sh.fill(pow2n((ns + w : Nat)), 0, 3, Array.new(U32, (ns + w : Nat), 0)))
    +t0 : Nat <- IO.now()
    +c : U32 <- IO.pure(U32, sh.tree(d, w, U32.from_nat(pow2n(ns)), reps, 1, Array.fork(U32, s)))
    +t1 : Nat <- IO.now()
    report(12, d, w, reps, ns, thr, (t1 - t0 : Nat), c)

def go.run(+mode: U32, +d: Nat, +w: Nat, +reps: Nat, +extra: Nat) -> IO(Unit):
  do IO<Unit>:
    +thr : U32 <- IO.thread_count()
    +t0 : Nat <- IO.now()
    +c : U32 <- IO.pure(U32, run(mode, d, w, reps, extra))
    +t1 : Nat <- IO.now()
    report(mode, d, w, reps, extra, thr, (t1 - t0 : Nat), c)

def go15(+d: Nat, +w: Nat, +reps: Nat, +ns: Nat) -> IO(Unit):
  do IO<Unit>:
    +thr : U32 <- IO.thread_count()
    s : Array<U32> <- IO.pure(Array<U32>, sh.fill(pow2n((ns + w : Nat)), 0, 3, Array.new(U32, (ns + w : Nat), 0)))
    +t0 : Nat <- IO.now()
    +c : U32 <- IO.pure(U32, sh.treec(d, w, U32.from_nat(pow2n(ns)), reps, 1, Array.clone(U32, s)))
    +t1 : Nat <- IO.now()
    report(15, d, w, reps, ns, thr, (t1 - t0 : Nat), c)

def go(+mode: U32, +d: Nat, +w: Nat, +reps: Nat, +extra: Nat) -> IO(Unit):
  match mode:
    case 12:
      go12(d, w, reps, extra)
    case 15:
      go15(d, w, reps, extra)
    case _:
      go.run(mode, d, w, reps, extra)

def rd(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def run_args(args: List<String>) -> IO(Unit):
  match args:
    case prog <> m <> d <> w <> r <> e <> rest:
      go(rd(m, 0), U32.to_nat(rd(d, 4)), U32.to_nat(rd(w, 10)), U32.to_nat(rd(r, 100)), U32.to_nat(rd(e, 1)))
    case _:
      IO.die(Unit, 1, "usage: lab [--threads N] -- mode D w reps extra")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run_args(args)
