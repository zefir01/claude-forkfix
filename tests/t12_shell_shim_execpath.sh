#!/usr/bin/env bash
# T-auto (regression, found in use): the Bash tool's shell snapshot shadows
# grep/find/pkill with functions that re-exec $CLAUDE_CODE_EXECPATH as a
# multicall binary (`exec -a ugrep "$_cc_bin" -G ...`). Upstream sets that var to
# process.execPath, which for the stock install is the single-file launcher that
# really contains ugrep/bfs. In the patched build process.execPath is the private
# bun, which is executable -- so the shim's `[[ -x $_cc_bin ]]` fallback does NOT
# trigger and bun gets handed ugrep's flags ("error: Invalid Argument '-G'" plus
# bun's help on stdout).
#
# Three checks, all offline:
#   1. the patch guards that one assignment with process.env.CLAUDE_CODE_EXECPATH
#   2. the launcher exports the pinned stock binary for it
#   3. the shim itself, replayed out of a real shell snapshot, works with the
#      stock binary and breaks with bun -- i.e. the value we pass is the value
#      that matters
# The end-to-end version (real Bash tool, both builds) is tests/m24.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

P="$FFX_ROOT/$(m patch.file)"
TREE="$FFX_ROOT/build/tree/$(m patch.target_basename)"
NORM="$FFX_ROOT/build/cli-normalized.js"
BUN="$FFX_ROOT/$(m runtime.bun_path)"
LAUNCH="$FFX_ROOT/scripts/run-patched.sh"
STOCK="$(stock_binary)"
rc=0

GUARDED='if(c[TJs]=process.env.CLAUDE_CODE_EXECPATH||process.execPath,l)c.TMUX=l;'
PLAIN='if(c[TJs]=process.execPath,l)c.TMUX=l;'

# ---- 1. patch/build shape
grep -qxF -e "-$PLAIN" "$P" || { echo "  FAIL patch does not remove the unconditional assignment"; rc=1; }
grep -qxF -e "+$GUARDED" "$P" || { echo "  FAIL patch does not add the guarded assignment"; rc=1; }
[ -f "$TREE" ] && [ -f "$NORM" ] || fail "run scripts/prepare-patched.sh first"
n="$(grep -cxF "$GUARDED" "$TREE")"
[ "$n" = "1" ] || { echo "  FAIL patched tree has $n guarded assignments (expected 1)"; rc=1; }
grep -qxF "$PLAIN" "$TREE" && { echo "  FAIL patched tree still has the unconditional assignment"; rc=1; }
grep -qxF "$PLAIN" "$NORM" || { echo "  FAIL upstream bundle no longer matches the expected assignment"; rc=1; }
grep -qxF "$GUARDED" "$NORM" && { echo "  FAIL upstream bundle already guarded (patch would be redundant)"; rc=1; }

# ---- 2. launcher passes the pinned stock binary, and nothing else new
grep -q 'CLAUDE_CODE_EXECPATH="\$(stock_binary)"' "$LAUNCH" \
  || { echo "  FAIL launcher does not export CLAUDE_CODE_EXECPATH=\$(stock_binary)"; rc=1; }
[ -x "$STOCK" ] || { echo "  FAIL pinned stock binary is not executable: $STOCK"; rc=1; }

# ---- 3. replay the real shim, once per candidate value of the variable
SNAP="$(ls -t "$HOME"/.claude/shell-snapshots/*.sh 2>/dev/null | while read -r f; do
          grep -q '_cc_bin' "$f" && { echo "$f"; break; }; done)"
if [ -z "$SNAP" ]; then
  echo "  note no shell snapshot with the grep/find shims found -- shim replay skipped"
else
  # extract just the `grep` function, so sourcing does not drag in the whole env
  FN="$(mktemp)"; awk '/^function grep \{$/{f=1} f{print} f&&/^\}$/{exit}' "$SNAP" > "$FN"
  grep -q '_cc_bin' "$FN" || { echo "  FAIL could not extract the grep shim from $SNAP"; rc=1; }
  probe() { # $1 = value for CLAUDE_CODE_EXECPATH -> shim stdout+stderr
    CLAUDE_CODE_EXECPATH="$1" bash --noprofile --norc -c \
      "source '$FN'; printf 'ffx-needle\n' | grep ffx-needle" 2>&1
  }
  with_stock="$(probe "$STOCK")"
  with_bun="$(probe "$BUN")"
  rm -f "$FN"
  echo "  shim replay: snapshot $(basename "$SNAP")"
  echo "    CLAUDE_CODE_EXECPATH=<stock binary> -> $(printf '%s' "$with_stock" | head -1 | cut -c1-60)"
  echo "    CLAUDE_CODE_EXECPATH=<private bun>  -> $(printf '%s' "$with_bun" | head -1 | cut -c1-60)"
  [ "$with_stock" = "ffx-needle" ] \
    || { echo "  FAIL shim does not work with the pinned stock binary"; rc=1; }
  [ "$with_bun" = "ffx-needle" ] \
    && { echo "  FAIL premise broken: the shim works with bun too, so this fix is untestable"; rc=1; }
fi

[ $rc = 0 ] && echo "  ok  shell shims get the stock multicall binary, upstream fallback preserved"
exit $rc
