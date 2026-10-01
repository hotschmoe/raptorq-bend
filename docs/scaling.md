# Scaling lab: what pure Bend 2.0.34 scales on this machine, and what it does not

Everything here is pure Bend (no foreign code), Bend 2.0.34, native binaries (`bend f.bend -o out`, system clang first in PATH), IO `main`.
Harness: `tools/scaling/lab.bend` (one binary, many patterns, mode = first argument), `tools/scaling/sweep.py` (min of 5 runs at 1/2/4/8/12
threads, prints ms and speedup), `tools/scaling/run_all.sh` (the whole table). Raw output of the run quoted below:
`tools/scaling/results.txt`.

## The machine, and how honest the numbers can be

* 12 cores, **not equal** (`/sys/devices/system/cpu/cpu*/cpu_capacity`): cpu0,1 Cortex-A720 @2.6 GHz (capacity 1024), cpu6,7 A720 @2.3
  (905), cpu8,9 A720 @2.2 (866), cpu10,11 A720 @2.5 (984), **cpu2-5 Cortex-A520 @1.8 GHz (capacity 279)**. Measured: the same 4-thread job takes
  15-18 ms on four A720 and 49-97 ms on the four A520s, i.e. a little core is ~3-4x slower. 8 big + 4 little cores are worth about 8.4 big cores at
  best, and the runtime deals each task to one thread once (never moves it), so a static split over 12 threads is gated by the slowest core.
  Rows with `t <= 8` are confined to the big cores (`taskset -c 0,1,6,7,8,9,10,11`), `t = 1` is pinned to cpu10, `t = 12` is unpinned.
* **The box was shared**: during this whole work a kernel build (`make -j11`, a different user job) kept the load average at 13-20 on 12 cores.
  Every multi-thread number is therefore a *lower bound* on what an idle machine would give (the sweep prints the load average on its first
  line). Single-thread pinned numbers are good to about +-10 %. I did not get an idle machine; the conclusions below are about orders of
  magnitude (1.0x vs 3x vs 0.05x), which a loaded box does not blur.

## Results (speedup vs 1 thread; ms in `tools/scaling/results.txt`)

| pattern | x2 | x4 | x8 | x12 | note |
|---|---|---|---|---|---|
| A. balanced fork tree, every leaf allocates its own `Array<U32>` and runs a tail-recursive read-modify-write kernel; leaf ~1 us (2^19 leaves) | 1.7 | 2.3 | 3.8 | 3.3 | |
| same, leaf ~10 us (2^16 leaves) | 2.0 | 2.8 | 3.8 | 2.6 | |
| same, leaf ~100 us (2^13) | 1.8 | 2.6 | 2.9 | 3.8 | |
| same, leaf ~1 ms (2^10) | 1.7 | 3.5 | 3.8 | 4.2 | |
| same, leaf ~10 ms (2^6) | 2.0 | 2.8 | 3.9 | 3.3 | |
| C. **forks reached from sequential code**, 8-leaf tree (85 us leaves) per round, 500 rounds | 0.79 | 0.75 | 0.72 | 0.55 | slower than sequential |
| same, 10 us leaves, 5000 rounds | 0.30 | 0.27 | 0.21 | 0.15 | one round costs 0.2-0.5 ms |
| same, 4 us leaves, 20000 rounds | 0.05 | 0.04 | 0.03 | 0.02 | |
| C'. the same work as ONE top-level region (leaves loop 500 / 5000 / 20000 times sequentially) | 1.8 | 3.0 | 3.7 | 3.4 | 1.8 / 2.6 / 3.3 / 3.4 and 1.5 / 2.4 / 3.2 / 2.7 for the shorter leaves |
| D. non-tail leaf recursion inside the tree (hash-chain sum) vs tail loop | 1.6 / 1.3 | 2.1 / 1.9 | 3.4 / 2.8 | 2.7 / 2.6 | both scale; non-tail is 2.6x slower in absolute terms even at 1 thread |
| D'. sequential non-tail walk that allocates nodes (the `Vec.xor` shape), NO fork in the def | 1.05 | 1.05 | 1.00 | 0.92 | no penalty at `--threads` > 1 |
| D''. **same walk, but the def also contains a fork branch (never taken)** (`G.Vec.xor.go` shape) | **0.44** | 0.41 | 0.45 | 0.41 | 2.3x slower than the fork-free def |
| D'''. same, fork-free branch moved into a **separate twin def** | 0.99 | 0.99 | 0.99 | 1.00 | penalty gone |
| E. ONE array cut by `match a: case ANode{l, r}` into 2^D slices, fork tree over them, re-joined with `ANode{x, y}` (2^13 slices x 4096 words) | 1.6 | 1.9 | 2.3 | 2.2 | memory-bound (128 MB array); at 2^6 slices of 16K words 1.75 / 2.75 / 3.1 / 2.5 |
| E'. same work, slice count 1 / 2^6 / 2^10 / 2^14 / 2^16 / 2^18 (leaf 2^18 / 2^12 / 2^8 / 2^4 / 2^2 / 1 words), 1 thread | | | | | 215 / 211 / 218 / 249 / 277 / 851 ms: a slice costs ~2 us, free from 16 words up |
| E''. tree of leaf arrays (`type At` = `At{Array}` / `An{At, At}`, built and worked inside tasks) | 1.9 | 2.4 | 3.2 | 3.3 | as good as pattern A |
| F. repair-generation shape: ONE shared read-only array through `Array.fork`, each leaf XORs a few symbols of it into its own output array (1024 leaves x 256 words, 40 symbols each: 14 ms of work) | 1.3 | 1.6 | 2.8 | 1.6 | (78 ms of work: 1.5 / 2.3 / 3.0 / 2.9) |
| G. a `Data` list (Solver.Plan-shaped, 16K elements) **shared** by all 16 leaves, each walks it 300 times | 1.7 | 2.4 | 2.3 | | atomic refcount traffic on shared nodes |
| G'. same, every leaf builds its **own** copy | 1.9 | 2.8 | 4.2 | | |
| serial control: 8192 leaf kernels in a plain loop, `--threads` 1/2/4/8/12 | 1.00 | 0.99 | 1.04 | 1.04 | tail loops over arrays do not care about `--threads` |

(Ideal for 4 / 8 / 12 threads on this machine: 4 / 8 / ~8.4 big-core equivalents. Under the load of 13-20 described above 3-4x at 8 threads is what
a balanced tree gets.)

## What the lab says (rules of thumb)

1. **Pure Bend does scale, on exactly one shape**: one top-level `a b = f(..) g(..)` tree (a balanced divide and conquer), tails of the recursion
   are tail-recursive loops over `Array<U32>` that the *leaf allocates itself*, no sharing between leaves. 2-3.8x at 8 threads here, down to leaves of
   ~1 us (a task costs tens of nanoseconds, not microseconds; the 0.3 ms cost is a *region*, see 3). Leaf size is therefore not critical: >= 10 us
   keeps the task overhead below 1 %. Depth: 2^3 - 2^6 tasks are enough, more tasks than threads (16 on 12) lose to a second wave.
2. **A big.LITTLE chip is a 3-4x scheduling cliff for static trees**: tasks are never moved, the 4 A520 are ~3.5x slower, so `--threads 12` is
   usually *worse* than `--threads 8` pinned to the big cores (x12 < x8 in most rows). Use `--threads 8` (and let the OS keep them on the big
   cores / `taskset`) on this machine; this is a runtime limit (no work stealing), not something the program can fix.
3. **A parallel region reached from sequential code costs 0.2-0.5 ms** (and grows with the thread count): any loop that forks per iteration
   is 0.3-0.02x of sequential (C). One region around the whole computation scales like A (C'). So: fork once, outermost, never inside a loop
   that runs from sequential code; a single block can use only ONE region per phase that has >> 1 ms of work.
4. **Non-tail recursion is fine at any `--threads` when the def contains no fork; a def that merely *contains* a parallel `let` makes all its
   non-tail calls heap-allocate continuation tasks at `--threads` > 1 (2.3x slower), even in the branch that never forks** (D'' vs D''').
   Rule: the fork-free recursion goes into its own twin def (like `tr.zip` called from `tr.zipg`); never put the leaf kernel in the same def as the fork.
   (This is the precise form of the `seq` finding in docs/profile.md section 6. It also means `G.Vec.xor/muladd/zeros/scale` pay it at `--threads`
   > 1 although they fork only above 4096 words: their `fk = 0` branch should call a twin.)
5. **Disjoint slices of one array are free**: `match a: case ANode{l, r}` hands out the two halves with no copy (a slice costs ~2 us at any size,
   indices are relative to the slice), and `ANode{x, y}` joins them. The array length must be a power of two, halves are halves. Equivalent and
   as fast: a tree of leaf arrays built inside the tasks. No chunking primitive is needed.
6. **Read-only sharing**: `Array.fork(U32, a)` (an `@unsafe` Base def, usable from user code) gives two handles of ONE array in O(1);
   reading through them from different tasks is correct (checksums equal at all thread counts) and scales (F). Pass the handle pair down the tree:
   `def tree(d, ..., r: Array<U32> & Array<U32>)` destructures `(s1, s2) = r` inside the match branch and recurses with
   `Array.fork(U32, s1)`, `Array.fork(U32, s2)`. **Sharing a `Data` structure (a list, e.g. `Solver.Plan`) between tasks is a scaling trap** (G vs G'):
   every match bumps refcounts atomically on nodes all tasks touch, 2.3x vs 4.2x at 8 threads, and a list walk costs ~18 ns per element anyway
   against ~1 ns per array slot. Shared inputs belong in flat arrays; per-task private data in whatever.
7. A task's own allocation is cheap (`Array.new` inside the leaf, tree-of-nodes building inside the leaf): allocation is per-lane, no global lock.
