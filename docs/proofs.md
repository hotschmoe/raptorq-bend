
## gf256 (`src/gf256.bend`, laws section at the bottom of the file)
Proven (`bend src/gf256.bend` -> ALL PROOFS CHECK; `--verdict` could not run: no Lean installed):
`bool_xor_comm`, `word_xor_comm`, `word_xor_self`, `word_xor_zero` (induction on Word width),
and for octet `add` (= U32.xor): `add_comm`, `add_self` (a+a=0), `add_zero`; plus `mul_zero_l`, `div_zero_l`.

Unproven (checked exhaustively by `tests/gf256_test.bend` over all 256x256 pairs instead):
TODO `mul` commutative, associative, distributive over `add`; `mul(1,a)=a`; `mul(a,inv a)=1` for a != 0;
`div(a,b)*b = a`; `add` associative; `oct_exp`/`oct_log` mutually inverse; table = RFC (a data fact, checked by the
generator); `mulw` = per-octet `mul` (SWAR correctness); `Vec.muladd` = zipWith over words;
`Vec.xor` self-inverse. The mul laws need either a bounded-quantifier encoding (octets < 256) or a
proof about the generated tables; both are large and were deliberately not attempted.
