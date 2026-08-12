#!/usr/bin/env bash
# Regression suite.
#   ./scripts/test-patch.sh              automated tests only (no model calls)
#   ./scripts/test-patch.sh --with-model also run tests/m*.sh (real API calls)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
set +e

WITH_MODEL=0
[ "${1:-}" = "--with-model" ] && WITH_MODEL=1

pass=0; failed=0
run() {
  local t="$1" name
  name="$(basename "$t")"
  echo "── $name"
  if bash "$t"; then echo "   PASS"; pass=$((pass+1)); else echo "   FAIL"; failed=$((failed+1)); fi
}

for t in "$FFX_ROOT"/tests/t*.sh; do run "$t"; done
if [ "$WITH_MODEL" = "1" ]; then
  for t in "$FFX_ROOT"/tests/m*.sh; do [ -e "$t" ] && run "$t"; done
else
  echo "── (skipping tests/m*.sh model tests; pass --with-model to include them)"
fi

echo
echo "PASS $pass   FAIL $failed"
[ "$failed" -eq 0 ]
