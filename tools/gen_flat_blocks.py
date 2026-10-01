#!/usr/bin/env python3
"""Emits the unrolled 16-word block reader `Flat.tv.b0 .. b15` of src/flat.bend (definitions come in reverse order because
Bend needs a def before its use).  Usage: tools/gen_flat_blocks.py [B=16]  > stdout; paste between the BEGIN/END markers."""
import sys
B = int(sys.argv[1]) if len(sys.argv) > 1 else 16
defs = []
stack = []
for i in range(B):
    args = "".join(f"+{s}: G.Vec, " for s in stack)
    new = list(stack) + ["G.VWord{x}"]
    k = i + 1
    while k % 2 == 0:
        r = new.pop(); l = new.pop()
        new.append(f"G.VNode{{{l}, {r}}}")
        k //= 2
    if i == B - 1:
        tail = f"  Bv{{{new[0]}, a}}"
    else:
        tail = f"  Flat.tv.b{i+1}({', '.join(new)}, base, Array.get(U32, a, (base + {i+1} : U32)))"
    defs.append(f"def Flat.tv.b{i}({args}+base: U32, r: Array<U32> & U32) -> Bv:\n  (a, x) = r\n{tail}")
    stack = [f"s{j}" for j in range(len(new))]
print("\n\n".join(reversed(defs)))
