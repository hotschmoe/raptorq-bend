# Helper definitions for LAWS.bend / PROOF.bend (docs/proofs.md).  Nothing here is used by the codec.
import Base
import ./gf256.bend as G

# Same shape: both trees have the same node/leaf structure (leaf contents ignored).
# G.Vec ops zip two vectors and are only meaningful on equal shapes.
def Same(a: G.Vec, b: G.Vec) -> Type:
  match a b:
    case G.VNil{} G.VNil{}:
      Unit
    case G.VWord{x} G.VWord{y}:
      Unit
    case G.VNode{al, ar} G.VNode{bl, br}:
      Same(al, bl) & Same(ar, br)
    case _ _:
      Empty

# The branch of G.Vec.muladd taken for every coefficient c other than 0 and 1 (muladd is
# `match c: 0 -> dst; 1 -> xor(dst, src); _ -> this`).
def muladd_nz(c: U32, +d: G.Vec, s: G.Vec) -> G.Vec:
  G.Vec.muladd.go(G.Vec.fork_levels(d), c, d, s)
