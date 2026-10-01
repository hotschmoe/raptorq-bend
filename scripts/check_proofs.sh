#!/bin/sh
# Proof gate for raptorq-bend (docs/proofs.md).
#   scripts/check_proofs.sh           PROOF.bend must print ALL PROOFS CHECK (exit 1 otherwise)
#   scripts/check_proofs.sh --runtime additionally run src/laws_check.bend (runtime-checked laws, ~10 s)
#   scripts/check_proofs.sh --tamper  additionally prove the gate has teeth: a scratch copy of the tree with a
#                                     deliberately broken def must make PROOF.bend fail
set -u
cd "$(dirname "$0")/.." || exit 2
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1
status=0

echo "== bend PROOF.bend"
out=$(bend PROOF.bend 2>&1)
echo "$out" | head -5
case "$out" in
  *"ALL PROOFS CHECK"*) echo "proofs: OK" ;;
  *) echo "proofs: FAILED"; status=1 ;;
esac
nlaws=$(grep -c '^law ' LAWS.bend)
nproof=$(grep -c '^def Laws\.' PROOF.bend)
echo "laws in LAWS.bend: $nlaws, proofs (def Laws.*) in PROOF.bend: $nproof"
[ "$nlaws" = "$nproof" ] || { echo "law/proof count mismatch"; status=1; }

echo "== open (unproven) laws, src/laws_open.bend"
open=$(bend src/laws_open.bend 2>&1 | sed -n 's/^Error: \([0-9]*\) TODO.*/\1/p')
echo "open laws: ${open:-0} (covered by runtime checks / exhaustive tests, see docs/proofs.md)"

for arg in "$@"; do
  case "$arg" in
    --runtime)
      echo "== bend src/laws_check.bend"
      r=$(bend src/laws_check.bend 2>&1)
      echo "$r"
      case "$r" in *"ALL LAW CHECKS PASS"*) ;; *) status=1 ;; esac ;;
    --tamper)
      echo "== tamper test"
      t=$(mktemp -d)
      cp -r LAWS.bend PROOF.bend src "$t"/
      # break Vec.xor on leaves: XOR becomes OR (as if somebody 'optimised' it)
      sed -i 's/VWord{U32.xor(x, y)}/VWord{U32.or(x, y)}/' "$t/src/gf256.bend"
      tout=$(cd "$t" && bend PROOF.bend 2>&1)
      echo "$tout" | head -12
      rm -rf "$t"
      case "$tout" in
        *"ALL PROOFS CHECK"*) echo "tamper: NOT DETECTED"; status=1 ;;
        *) echo "tamper: detected (proof fails as it must)" ;;
      esac ;;
  esac
done
exit $status
