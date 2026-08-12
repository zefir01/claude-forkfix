#!/usr/bin/env bash
# T-auto: the patch is small, touches one file, changes exactly two existing
# lines, and cannot affect non-fork agents (static guard check).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

P="$FFX_ROOT/$(m patch.file)"
rc=0

files="$(grep -c '^--- ' "$P")"
[ "$files" = "1" ] || { echo "  FAIL patch touches $files files"; rc=1; }
hunks="$(grep -c '^@@ ' "$P")"
[ "$hunks" = "3" ] || { echo "  FAIL patch has $hunks hunks (expected 3)"; rc=1; }
del="$(grep -c '^-' "$P")"; del=$((del - 1))   # minus the `--- a/cli.js` header
add="$(grep -c '^+' "$P")"; add=$((add - 1))   # minus the `+++ b/cli.js` header
[ "$del" = "2" ] || { echo "  FAIL patch removes $del lines (expected 2)"; rc=1; }
echo "  1 file, $hunks hunks, -$del/+$add lines"

# removed line 1: the fork/non-fork system-prompt selection in Z5
grep -q '^-St=d?.systemPrompt?d.systemPrompt:of(await _Eb(e,r,ie,Je)),$' "$P" \
  || { echo "  FAIL unexpected removed line (Z5 system prompt)"; rc=1; }
grep -q '^+St=d?.systemPrompt?ffxForkSystemPrompt(d.systemPrompt,e,t,Q):of(await _Eb(e,r,ie,Je)),$' "$P" \
  || { echo "  FAIL unexpected replacement line (Z5 system prompt)"; rc=1; }
# removed line 2: the shell-shim exec path (see tests/t12 for what it fixes)
grep -q '^-if(c\[hQs\]=process.execPath,l)c.TMUX=l;$' "$P" \
  || { echo "  FAIL unexpected removed line (shim exec path)"; rc=1; }
grep -q '^+if(c\[hQs\]=process.env.CLAUDE_CODE_EXECPATH||process.execPath,l)c.TMUX=l;$' "$P" \
  || { echo "  FAIL unexpected replacement line (shim exec path)"; rc=1; }

# non-fork guard must be the first statement of the wrapper
python3 - "$P" <<'PY'
import re, sys
p = open(sys.argv[1], encoding='utf-8').read()
added = "\n".join(l[1:] for l in p.splitlines() if l.startswith('+') and not l.startswith('+++'))
m = re.search(r'function ffxForkSystemPrompt\(e, t, r, n\) \{\s*\n\s*(.+)', added)
if not m or m.group(1).strip() != 'if (t?.agentType !== ake) return e;':
    print("  FAIL non-fork guard is not the first statement"); sys.exit(1)
if 'ake' not in added:
    print("  FAIL fork type constant not used"); sys.exit(1)
print("  non-fork guard present: `if (t?.agentType !== ake) return e;` (identical value returned)")
PY
rc=$(( rc + $? ))
exit $rc
