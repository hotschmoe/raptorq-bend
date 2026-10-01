
# ===========================================================================
# PROFILING HARNESS (scratch copy only): Solver.cut(stage, l, p, rows) runs the pipeline up to `stage` and returns a checksum
# that forces everything computed so far.  0 = row normalisation + index build, 1 = + phase 1 loop, 2 = + log replay (mat_pivs),
# 3 = + leftover rows + dense-row correction, 4 = + tail Gauss-Jordan, 5 = everything (phase 3).
# ===========================================================================
def cx_vs(v: G.Vec, acc: U32) -> U32:
  match v:
    case G.VNode{l, r}:
      cx_vs(r, cx_vs(l, acc))
    case G.VWord{w}:
      (acc .^. (w * 31 + 7 : U32) : U32)
    case G.VNil{}:
      acc

def cx_len(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      cx_len(t, (acc + h + 1 : U32))

def cx_pv(pvs: List<&2, Pv>, +acc: U32) -> U32:
  match pvs:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case Pv{pc, pcf, own, log, oc, r0}:
          cx_pv(t, cx_vs(r0, (acc + pc + pcf + U32.from_nat(List.length(&2, T.Term, own)) + U32.from_nat(List.length(&2, Lg, log)) + U32.from_nat(List.length(&2, T.Term, oc)) : U32)))

def cx_arr(n: Nat, +k: U32, acc: U32, r: Array<VR> & VR) -> U32:
  match n r:
    case 0n _:
      acc
    case 1n+p Tuple{ar, VR{v, rr}}:
      cx_arr(p, (k + 1 : U32), cx_vs(rr, cx_vs(v, acc)), Array.get(VR, ar, (k + 1 : U32)))

def cx_dt(ts: List<&2, DT>, acc: U32) -> U32:
  match ts:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case DTLeaf{DG{id, piv, co, rhs}}:
          cx_dt(t, cx_vs(rhs, cx_vs(co, acc)))
        case _:
          cx_dt(t, acc)

def cx_pr(ps: List<&2, Pr>, acc: U32) -> U32:
  match ps:
    case Nil{}:
      acc
    case Pr{k, v} <> t:
      cx_pr(t, cx_vs(v, acc))

def cx_res(r: Maybe<&2, List<&2, Pr>>) -> U32:
  match r:
    case None{}:
      0
    case Some{ps}:
      cx_pr(ps, 1)

def cx_ts(lr: LR, dn: List<&2, Rw>, +ci: List<&2, U32>, +nw: U32, +nwd: U32, ords: List<&2, Pv>) -> List<&2, DT>:
  match lr:
    case LR{ar, out}:
      ds_dgs(ds_fin(ds_loop(ords, 0, nw, DM{ar, ds_init(dn, ci, nw, nwd, 1000000000)})), out)

def cx_sel(stage: U32, +n: U32, +ci: List<&2, U32>, rs: List<&2, Rw>, +dn: List<&2, Rw>, +pivs: List<&2, Pv>, +l: U32, +sw: U32, +nw: U32, +ords: List<&2, Pv>, +nwd: U32, +zero: G.Vec, +np: U32) -> U32:
  match stage:
    case 2:
      cx_arr(U32.to_nat(np), 0, 0, Array.get(VR, mat_pivs(ords, 0, nwd, zero, Array.new(VR, clog(np), VR{G.VNil{}, G.VNil{}})), 0))
    case 3:
      cx_dt(cx_ts(lr_loop(rs, nwd, zero, 1, LR{mat_pivs(ords, 0, nwd, zero, Array.new(VR, clog(np), VR{G.VNil{}, G.VNil{}})), Nil{}}), dn, ci, nw, nwd, ords), 0)
    case _:
      cx_res(dg_run_s(par_for(n, (sw + nwd : U32)), dt_build(32n, cx_ts(lr_loop(rs, nwd, zero, 1, LR{mat_pivs(ords, 0, nwd, zero, Array.new(VR, clog(np), VR{G.VNil{}, G.VNil{}})), Nil{}}), dn, ci, nw, nwd, ords)), n, nwd))

def cx_go(stage: U32, +ci: List<&2, U32>, rs: List<&2, Rw>, +dn: List<&2, Rw>, +pivs: List<&2, Pv>, +l: U32, +sw: U32, +nw: U32) -> U32:
  +n = U32.from_nat(List.length(&2, U32, ci))
  +ords = List.reverse(&2, Pv, pivs)
  +nwd = nwords(n)
  +zero = zero_vec(nwd)
  +np = U32.from_nat(List.length(&2, Pv, pivs))
  cx_sel(stage, n, ci, rs, dn, pivs, l, sw, nw, ords, nwd, zero, np)

def cx_p2(stage: U32, rs: List<&2, Rw>, dn: List<&2, Rw>, +pivs: List<&2, Pv>, il: List<&2, U32>, +p: U32, +l: U32, sw: U32, +nw: U32) -> U32:
  +perm = perm_cols(U32.to_nat(p), (l - p : U32))
  +dyn = List.reverse(&2, U32, il)
  cx_go(stage, phase2.cl2(perm, dyn, List.append(&2, U32, pivcols(pivs, Nil{}), List.append(&2, U32, dyn, perm)), l), rs, dn, pivs, l, sw, nw)

def cx_p1b(stage: U32, pivs: Pl, rs: List<&2, Rw>, dn: List<&2, Rw>, +l: U32, sw: U32, +nw: U32) -> U32:
  match stage pivs:
    case 1 Pl{n, pl, nin, il, p}:
      (cx_pv(pl, 0) + cx_len(il, 0) : U32)
    case _ Pl{n, pl, nin, il, p}:
      cx_p2(stage, rs, dn, pl, il, p, l, sw, nw)

def cx_p1(stage: U32, st: P1, l: U32, sw: U32, nw: U32) -> U32:
  match st:
    case P1{rows, wt, bk, ci, dn, pivs, done}:
      cx_p1b(stage, pivs, arr_rows(rows, Nil{}), dn, l, sw, nw)

def cx_fst(r: Array<U32> & U32) -> U32:
  match r:
    case Tuple{a, x}:
      x

def cx_p0(st: P1) -> U32:
  match st:
    case P1{rows, wt, bk, ci, dn, pivs, done}:
      cx_fst(Array.get(U32, wt, 0))

def cx_stage2(stage: U32, +l: U32, +p: U32, +sw: U32, +nrows: U32, rows: List<&2, T.Row>, +nw: U32) -> U32:
  match stage:
    case 0:
      cx_p0(p1_of(init_go(rows, l, p, zero_vec(nw), nw, 0, in_new(nrows, l)), p))
    case _:
      cx_p1(stage, phase1(l, p, nrows, rows, nw), l, sw, nw)

def cx_stage(stage: U32, +l: U32, +p: U32, +sw: U32, +nrows: U32, rows: List<&2, T.Row>) -> U32:
  cx_stage2(stage, l, p, sw, nrows, rows, nwords(l))

def Solver.cut(stage: U32, +l: U32, +p: U32, +rows: List<&2, T.Row>) -> U32:
  cx_stage(stage, l, p, rows_sw(rows), U32.from_nat(List.length(&2, T.Row, rows)), rows)
