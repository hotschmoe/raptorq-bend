# Runtime checks for the laws that are NOT proven in PROOF.bend (docs/proofs.md, table of laws).
# Run:  bend src/laws_check.bend      (prints one line per law, "ALL LAW CHECKS PASS"; exit 1 on failure)
#  rand_bound        Rand[y,i,m] < m for m > 0 (LCG-sampled y, i, m incl. edge values)
#  params_lookup     for every K in 0..56403: K <= K', K' is a Table 2 row (fixed point), K' monotone in K,
#                    L = K'+S+H, P = L-W, U = P-H, B = W-S; spot values of the RFC table
#  split_join        split gives K = ceil(len/T) symbols of ceil(T/4) words, zero padded; join(split(d)) = d
#  decode_checked    decode_checked agrees with decode on consistent input and recovers the source; with one
#                    corrupted symbol among K+2 received symbols plain decode accepts and decode_checked
#                    returns None; verify rejects a tampered solution
import Base
import ./gf256.bend as G
import ./types.bend as Y
import ./tables.bend as T
import ./rfc_funcs.bend as R
import ./constraints.bend as C
import ./solver.bend as S
import ./raptorq.bend as Q
import ./laws_verify.bend as V

def fail(b: Bool) -> U32:
  match b:
    case True{}:
      0
    case False{}:
      1

def lcg(+x: U32) -> U32:
  (x * 1664525 + 1013904223 : U32)

def lst_eq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      Bool.and(U32.is_eq(x, y), lst_eq(xs, ys))
    case _ _:
      False{}

def syms_eq(a: List<&2, G.Vec>, b: List<&2, G.Vec>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      Bool.and(V.Vec.eq(x, y), syms_eq(xs, ys))
    case _ _:
      False{}

# ---------------------------------------------------------------------------
# rand_bound
# ---------------------------------------------------------------------------

def rb.one(+y: U32, +i: U32, +m: U32) -> U32:
  fail(U32.is_lt(R.rand(y, i, m), m))

def rb.go(n: Nat, +x: U32, bad: U32) -> U32:
  match n:
    case 0n:
      bad
    case 1n+p:
      +x1 = lcg(x)
      +x2 = lcg(x1)
      +x3 = lcg(x2)
      rb.go(p, x3, (bad + rb.one(x1, (U32.shrn(x2, 28n) .&. 7 : U32), (U32.shrn(x3, 12n) + 1 : U32)) + rb.one(x2, (x3 .&. 255 : U32), ((x1 .&. 1048575 : U32) + 1 : U32)) : U32))

def rb.edges() -> U32:
  (rb.one(0, 0, 1) + rb.one(4294967295, 255, 1) + rb.one(4294967295, 7, 4294967295) + rb.one(4294967295, 0, 1048576) + rb.one(0, 0, 4294967295) + rb.one(2147483648, 3, 2) + rb.one(1, 1, 2) + rb.one(305419896, 5, 56403) : U32)

# ---------------------------------------------------------------------------
# params_lookup
# ---------------------------------------------------------------------------

def kp_of(m: Maybe<&2, T.SP>) -> U32:
  match m:
    case None{}:
      0
    case Some{sp}:
      R.Kp(sp)

# K' of the next row, or the maximum U32 when K is out of range
def kp_hi(m: Maybe<&2, T.SP>) -> U32:
  match m:
    case None{}:
      4294967295
    case Some{sp}:
      R.Kp(sp)

def pm.sp(m: Maybe<&2, T.SP>, +k: U32) -> U32:
  match m:
    case None{}:
      1
    case Some{+sp}:
      +l = (R.Kp(sp) + R.S(sp) + R.H(sp) : U32)
      (fail(U32.is_le(k, R.Kp(sp))) + fail(U32.is_eq(R.L(sp), l)) + fail(U32.is_eq(R.P(sp), (l - R.W(sp) : U32)))
        + fail(U32.is_eq(R.U(sp), (R.P(sp) - R.H(sp) : U32))) + fail(U32.is_eq(R.B(sp), (R.W(sp) - R.S(sp) : U32)))
        + fail(U32.is_eq(kp_of(R.params(R.Kp(sp))), R.Kp(sp))) + fail(U32.is_le(R.Kp(sp), kp_hi(R.params((k + 1 : U32)))))
        + fail(U32.is_ge(R.Kp(sp), 10)) + fail(U32.is_lt(R.P(sp), R.L(sp))) : U32)

def pm.go(n: Nat, +k: U32, bad: U32) -> U32:
  match n:
    case 0n:
      bad
    case 1n+p:
      pm.go(p, (k + 1 : U32), (bad + pm.sp(R.params(k), k) : U32))

def pm.none.go(m: Maybe<&2, T.SP>) -> U32:
  match m:
    case None{}:
      0
    case Some{sp}:
      1

def pm.none() -> U32:
  pm.none.go(R.params(56404))

def pm.spot() -> U32:
  (fail(U32.is_eq(kp_of(R.params(0)), 10)) + fail(U32.is_eq(kp_of(R.params(10)), 10)) + fail(U32.is_eq(kp_of(R.params(11)), 12))
    + fail(U32.is_eq(kp_of(R.params(13)), 18)) + fail(U32.is_eq(kp_of(R.params(26)), 26)) + fail(U32.is_eq(kp_of(R.params(27)), 30))
    + fail(U32.is_eq(kp_of(R.params(56403)), 56403)) + pm.none() : U32)

# ---------------------------------------------------------------------------
# split_join
# ---------------------------------------------------------------------------

def bytes.go(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      bytes.go(p, lcg(x), U32.shrn(lcg(x), 24n) <> acc)

def bytes_of(+n: U32, +seed: U32) -> List<&2, U32>:
  bytes.go(U32.to_nat(n), seed, [])

def zeros_n(n: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      zeros_n(p, 0 <> acc)

# every symbol has ceil(t/4) words
def words_ok(ss: List<&2, G.Vec>, +tw: U32) -> U32:
  match ss:
    case Nil{}:
      0
    case Con{v, rest}:
      (fail(U32.is_eq(U32.from_nat(List.length(&2, U32, G.Vec.to_list(v, Nil{}))), tw)) + words_ok(rest, tw) : U32)

def sj.case(+len: U32, +t: U32) -> U32:
  +seed = (len * 31 + t : U32)
  +ss = Q.Codec.split(bytes_of(len, seed), t)
  +k = Q.len_sym(ss, 0)
  +kk = U32.max(1, ((len + t - 1) / t : U32))
  (fail(U32.is_eq(k, kk)) + words_ok(ss, U32.shrn((t + 3 : U32), 2n)) + fail(lst_eq(Q.Codec.join(ss, t, len), bytes_of(len, seed)))
    + fail(lst_eq(Q.Codec.join(ss, t, (kk * t : U32)), List.append(&2, U32, bytes_of(len, seed), zeros_n(U32.to_nat((kk * t - len : U32)), [])))) : U32)

def sj.loop(xs: List<&2, U32>, bad: U32) -> U32:
  match xs:
    case +len <> +t <> rest:
      sj.loop(rest, (bad + sj.case(len, t) : U32))
    case _:
      bad

def sj.cases() -> List<&2, U32>:
  [0, 4, 1, 4, 1, 1, 3, 4, 4, 4, 5, 4, 7, 4, 16, 16, 17, 16, 5, 5, 6, 5, 10, 5, 11, 5, 100, 7, 1001, 16, 1000, 4, 4096, 4, 33, 1, 9, 3, 64, 8, 65, 8]

# ---------------------------------------------------------------------------
# decode_checked / verify
# ---------------------------------------------------------------------------

def ones(n: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      ones(p, 1 <> acc)

def rcv_repair(n: Nat, +esi: U32, +e: Q.Enc, acc: List<&2, Y.Rcv>) -> List<&2, Y.Rcv>:
  match n:
    case 0n:
      acc
    case 1n+p:
      rcv_repair(p, (esi + 1 : U32), e, Y.Rcv{esi, Q.Codec.symbol(e, esi)} <> acc)

# flips the low bit of every octet-0 of the first received symbol
def corrupt(xs: List<&2, Y.Rcv>, +tw: Nat) -> List<&2, Y.Rcv>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{h, rest}:
      match h:
        case Y.Rcv{esi, sym}:
          Y.Rcv{esi, G.Vec.xor(sym, G.Vec.from_list(ones(tw, [])))} <> rest

def some_eq(m: Maybe<&2, List<&2, G.Vec>>, exp: List<&2, G.Vec>) -> U32:
  match m:
    case None{}:
      1
    case Some{out}:
      fail(syms_eq(out, exp))

def is_none(m: Maybe<&2, List<&2, G.Vec>>) -> U32:
  match m:
    case None{}:
      0
    case Some{x}:
      1

def is_some(m: Maybe<&2, List<&2, G.Vec>>) -> U32:
  match m:
    case None{}:
      1
    case Some{x}:
      0

def dc.enc(m: Maybe<&2, Q.Enc>, +src: List<&2, G.Vec>, +k: U32, +t: U32) -> U32:
  match m:
    case None{}:
      1
    case Some{+e}:
      +rv = rcv_repair(U32.to_nat((k + 2 : U32)), k, e, [])
      +bad = corrupt(rv, U32.to_nat(U32.shrn((t + 3 : U32), 2n)))
      (some_eq(V.Codec.decode_checked(k, t, rv), src) + some_eq(Q.Codec.decode(k, t, rv), src)
        + is_none(V.Codec.decode_checked(k, t, bad)) + is_some(Q.Codec.decode(k, t, bad)) : U32)

def dc.case(+k: U32, +t: U32) -> U32:
  +src = Q.Codec.split(bytes_of((k * t : U32), (k * 977 + t : U32)), t)
  dc.enc(Q.Codec.encoder(k, t, src), src, k, t)

# verify on a real system: golden solution passes, one flipped symbol fails
def vf.tamper(xs: List<&2, G.Vec>, +tw: Nat) -> List<&2, G.Vec>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{h, rest}:
      G.Vec.xor(h, G.Vec.from_list(ones(tw, []))) <> rest

def vf.sol(m: Maybe<&2, List<&2, G.Vec>>, +rows: List<&2, Y.Row>, +tw: Nat) -> U32:
  match m:
    case None{}:
      1
    case Some{+sol}:
      (fail(V.verify(rows, sol)) + fail(Bool.not(V.verify(rows, vf.tamper(sol, tw)))) : U32)

def vf.sp(m: Maybe<&2, T.SP>, +src: List<&2, G.Vec>, +t: U32) -> U32:
  match m:
    case None{}:
      1
    case Some{+sp}:
      +rows = Q.append_rows(C.fixed(sp, t), C.source_rows(sp, src))
      vf.sol(S.Solver.solve_p(R.L(sp), R.P(sp), rows), rows, U32.to_nat(U32.shrn((t + 3 : U32), 2n)))

def vf.case(+k: U32, +t: U32) -> U32:
  +src = Q.Codec.split(bytes_of((k * t : U32), (k * 977 + t : U32)), t)
  vf.sp(R.params(k), src, t)

# ---------------------------------------------------------------------------

def line(name: String, +bad: U32) -> IO(U32):
  do IO<U32>:
    IO.print(name ++ ": " ++ Bool.pick(String, U32.is_eq(bad, 0), "ok", "FAILED (" ++ U32.show(bad) ++ ")"))
    IO.pure(U32, bad)

def finish(bad: U32) -> IO(Unit):
  match bad:
    case 0:
      IO.print("ALL LAW CHECKS PASS")
    case _:
      IO.die(Unit, 1, "LAW CHECKS FAILED: " ++ U32.show(bad))

def main() -> IO(Unit):
  do IO<Unit>:
    +a : U32 <- line("rand_bound (20000 x 2 samples + edges)", (rb.go(20000n, 12345, 0) + rb.edges() : U32))
    +b : U32 <- line("params_lookup (all K in 0..56403)", (pm.go(56404n, 0, 0) + pm.spot() : U32))
    +c : U32 <- line("split_join (21 shapes)", sj.loop(sj.cases(), 0))
    +d : U32 <- line("verify rejects tampered solutions (K=1,10,26)", (vf.case(1, 4) + vf.case(10, 16) + vf.case(26, 5) : U32))
    +e : U32 <- line("decode_checked (K=1,10,26,50)", (dc.case(1, 4) + dc.case(10, 16) + dc.case(26, 5) + dc.case(50, 16) : U32))
    finish((a + b + c + d + e : U32))
