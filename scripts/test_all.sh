#!/usr/bin/env bash
# Runs every tests/*_test.bend with `bend` (interpreted, nothing is built) and, if present, scripts/check_proofs.sh.
# Prints PASS/FAIL per suite and a summary; exits 1 if any suite failed.   Usage: scripts/test_all.sh [name-filter]
set -u
cd "$(dirname "$0")/.."
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1
FILTER=${1:-}
LOGDIR=$(mktemp -d)
pass=0; fail=0; failed=()

run_suite() { # name, command...
  local name=$1; shift
  local start=$SECONDS
  if "$@" >"$LOGDIR/$name.log" 2>&1; then
    printf 'PASS  %-28s (%ds)\n' "$name" $((SECONDS - start)); pass=$((pass + 1))
  else
    printf 'FAIL  %-28s (%ds)  log: %s\n' "$name" $((SECONDS - start)) "$LOGDIR/$name.log"
    tail -n 5 "$LOGDIR/$name.log" | sed 's/^/        /'
    fail=$((fail + 1)); failed+=("$name")
  fi
}

for f in tests/*_test.bend; do
  name=$(basename "$f" .bend)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  run_suite "$name" bend "$f"
done

if [[ -x scripts/check_proofs.sh || -f scripts/check_proofs.sh ]]; then
  if [[ -z "$FILTER" || "proofs" == *"$FILTER"* ]]; then
    run_suite proofs bash scripts/check_proofs.sh
  fi
else
  echo "SKIP  proofs (scripts/check_proofs.sh not found)"
fi

echo "----"
echo "$pass suite(s) passed, $fail failed${failed[*]:+: ${failed[*]}}"
[[ $fail -eq 0 ]]
