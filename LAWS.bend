# LAWS.bend -- properties raptorq-bend must never break.  PROOF.bend proves every law here
# (`bend PROOF.bend` -> ALL PROOFS CHECK; scripts/check_proofs.sh).  Laws we cannot prove yet live in
# src/laws_open.bend and are covered by runtime checks / tests; docs/proofs.md has the status table.
# Notation: G = GF(256) + symbol vectors, `G.add` is octet addition (XOR), D.Same(a, b) = equal tree shape.
import Base
import ./src/gf256.bend as G
import ./src/laws_defs.bend as D
import ./src/types.bend as Y
import ./src/laws_verify.bend as V
import ./src/raptorq.bend as Q
import ./src/rfc_funcs.bend as R
import ./src/tables.bend as T

# ===== 1. A checked solution satisfies every equation ================================================

# verify == True means sum_i coef_i * C[col_i] == rhs for EVERY row (muladd/nth semantics, V.Row.eval)
law verify_sound:
  for +rows: List<&2, Y.Row>
  for +sol: List<&2, G.Vec>
  for  e: {V.verify(rows, sol) == True{} : Bool}
  V.Sat(rows, sol)

# Solver.solve_checked answers Some(sol) only when verify holds for sol
law solve_checked_sound:
  for +l: U32
  for +p: U32
  for +rows: List<&2, Y.Row>
  for +sol: List<&2, G.Vec>
  for  e: {V.Solver.solve_checked(l, p, rows) == Some{sol} : Maybe<&2, List<&2, G.Vec>>}
  {V.verify(rows, sol) == True{} : Bool}

# ===== 2. Symbol XOR (the hot operation of encoder and decoder) =======================================

law xor_self:
  for +a: G.Vec
  {G.Vec.xor(a, a) == G.Vec.zeros(a) : G.Vec}

law xor_zero:
  for +a: G.Vec
  {G.Vec.xor(a, G.Vec.zeros(a)) == a : G.Vec}

law xor_comm:
  for +a: G.Vec
  for +b: G.Vec
  for  s: D.Same(a, b)
  {G.Vec.xor(a, b) == G.Vec.xor(b, a) : G.Vec}

law xor_assoc:
  for +a: G.Vec
  for +b: G.Vec
  for +c: G.Vec
  for  s1: D.Same(a, b)
  for  s2: D.Same(b, c)
  {G.Vec.xor(G.Vec.xor(a, b), c) == G.Vec.xor(a, G.Vec.xor(b, c)) : G.Vec}

# adding the same symbol twice undoes it (row operations are reversible), for any shapes
law xor_inv:
  for +a: G.Vec
  for +b: G.Vec
  {G.Vec.xor(G.Vec.xor(a, b), b) == a : G.Vec}

# the result has the shape of the first operand, even when the operands' shapes differ
law xor_shape:
  for +a: G.Vec
  for +b: G.Vec
  D.Same(G.Vec.xor(a, b), a)

# ===== 3. dst ^= c * src ===============================================================================

law muladd_zero:
  for +d: G.Vec
  for +s: G.Vec
  {G.Vec.muladd(0, d, s) == d : G.Vec}

law muladd_one:
  for +d: G.Vec
  for +s: G.Vec
  {G.Vec.muladd(1, d, s) == G.Vec.xor(d, s) : G.Vec}

# D.muladd_nz is the branch of Vec.muladd taken for c not in {0, 1}; applying it twice restores dst
law muladd_invol:
  for +c: U32
  for +d: G.Vec
  for +s: G.Vec
  {D.muladd_nz(c, D.muladd_nz(c, d, s), s) == d : G.Vec}

# ===== 4. Octet addition (GF(256) addition is XOR) =====================================================

law add_comm:
  for +a: U32
  for +b: U32
  {G.add(a, b) == G.add(b, a) : U32}

law add_assoc:
  for +a: U32
  for +b: U32
  for +c: U32
  {G.add(G.add(a, b), c) == G.add(a, G.add(b, c)) : U32}

law add_self:
  for +a: U32
  {G.add(a, a) == 0 : U32}

law add_zero:
  for +a: U32
  {G.add(a, 0) == a : U32}

# ===== 5. Byte <-> symbol framing ======================================================================

# Codec.split returns exactly K = k_of(len, T) source symbols
law split_length:
  for +data: List<&2, U32>
  for +t: U32
  {List.length(&2, G.Vec, Q.Codec.split(data, t)) == U32.to_nat(Q.Codec.k_of(Q.len_u32(data, 0), t)) : Nat}

# ===== 6. Derived parameters (RFC 5.3.3.3) =============================================================

law params_L:
  for +sp: T.SP
  {R.L(sp) == (R.Kp(sp) + R.S(sp) + R.H(sp) : U32) : U32}

law params_P:
  for +sp: T.SP
  {R.P(sp) == (R.L(sp) - R.W(sp) : U32) : U32}

law params_B:
  for +sp: T.SP
  {R.B(sp) == (R.W(sp) - R.S(sp) : U32) : U32}
