#!/usr/bin/env bash
# T-auto: source-tree separation. The patched tree lives only inside this repo's
# build/ directory; nothing of ours is inside the stock installation.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

rc=0
STOCK_ROOT="$(dirname "$(dirname "$(stock_binary)")")"
TREE="$FFX_ROOT/build/tree/$(m patch.target_basename)"

case "$(readlink -f "$TREE")" in
  "$(readlink -f "$STOCK_ROOT")"/*) echo "  FAIL patched tree is inside the stock install root"; rc=1 ;;
  *) echo "  patched tree outside stock root: $TREE" ;;
esac

if grep -rIl 'forkfix\|ffxFork' "$STOCK_ROOT" "$HOME/.local/bin" 2>/dev/null | grep -q .; then
  echo "  FAIL forkfix artifacts found inside the stock installation"; rc=1
fi

# the stock binary must not contain the patch
if grep -qa 'ffxForkSystemPrompt' "$(stock_binary)"; then
  echo "  FAIL stock binary contains patched code"; rc=1
else
  echo "  stock binary contains no patched code"
fi
# ...and the patched tree must
grep -qa 'ffxForkSystemPrompt' "$TREE" || { echo "  FAIL patched tree lacks the patch"; rc=1; }

exit $rc
