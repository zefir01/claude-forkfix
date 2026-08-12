#!/usr/bin/env bash
# T10: an ordinary (non-fork) subagent must be identical on stock and patched.
# The patch's guard is `if (t?.agentType !== rxe) return e`, so a general-purpose
# subagent must get the *identical value* back.
#
# Two independent checks:
#   1. RUNTIME CAPTURE (authoritative): both builds instrumented by
#      scripts/make-debug-tree.py record the SHA-256 of the exact system prompt
#      handed to the API. For a non-fork subagent the two hashes must be equal,
#      and neither may contain <fork-control>/<TASK>.
#   2. the subagent's own answer, kept as a cross-check of the same claim.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

BUN="$FFX_ROOT/$(m runtime.bun_path)"
DBG="$FFX_ROOT/build/debug"
TREE="$FFX_ROOT/build/tree/$(m patch.target_basename)"
NORM="$FFX_ROOT/build/cli-normalized.js"
rc=0

[ -f "$TREE" ] && [ -f "$NORM" ] || fail "run scripts/prepare-patched.sh first"
mkdir -p "$DBG"
python3 "$FFX_ROOT/scripts/make-debug-tree.py" "$TREE" "$DBG/patched-cli.js" >/dev/null || fail "instrumenting patched tree"
python3 "$FFX_ROOT/scripts/make-debug-tree.py" "$NORM" "$DBG/stock-cli.js"   >/dev/null || fail "instrumenting unpatched bundle"

DIRECTIVE='FFX_NONFORK_PROBE: Do not call any tools and do not write any files. Answer in exactly two lines. Line 1: FORK_CONTROL=YES if your system prompt contains a block named <fork-control>, otherwise FORK_CONTROL=NO. Line 2: TASK_BLOCK=YES if your system prompt contains a <TASK> block, otherwise TASK_BLOCK=NO.'

PROMPT="Call the Agent tool once with subagent_type \"general-purpose\" and exactly this prompt, passed through character for character:

$DIRECTIVE

Then reply with exactly what the subagent returned, verbatim, and nothing else."

norm() { grep -o "FORK_CONTROL=[A-Z]*\|TASK_BLOCK=[A-Z]*" | tr '\n' ' '; }

# Both builds must run in the SAME cwd: the working directory is part of the
# system prompt, so different paths alone would make the hashes differ.
WORK="/tmp/ffx-m23"
rm -rf "$WORK"; mkdir -p "$WORK"

run() { # $1 = stock|patched -> prints the normalized answer; capture in /tmp/ffx-m23-$1.jsonl
  local kind="$1" work="$WORK" cap="/tmp/ffx-m23-$1.jsonl"
  rm -f "$cap"
  ( cd "$work" && FFX_DEBUG_FILE="$cap" DISABLE_AUTOUPDATER=1 \
      "$BUN" "$DBG/$kind-cli.js" -p --permission-mode bypassPermissions \
      --strict-mcp-config "$PROMPT" 2>&1 ) | norm
}

S="$(run stock)"
P="$(run patched)"
echo "  stock   subagent answer: ${S:-(nothing)}"
echo "  patched subagent answer: ${P:-(nothing)}"

python3 - <<'PY'
import json, sys
def rows(p):
    try:
        return [json.loads(l) for l in open(p, encoding='utf-8', errors='replace') if l.strip()]
    except FileNotFoundError:
        return []
s, p = rows('/tmp/ffx-m23-stock.jsonl'), rows('/tmp/ffx-m23-patched.jsonl')
rc = 0
print("  captured system prompts: stock=%d patched=%d" % (len(s), len(p)))
if not s or not p:
    print("  FAIL no runtime capture on one of the builds (subagent never started?)"); sys.exit(1)
for kind, rs in (("stock", s), ("patched", p)):
    bad = [r for r in rs if r["has_fork_control"] or r["has_TASK"]]
    if bad:
        print("  FAIL %s: non-fork subagent prompt contains fork-control/TASK" % kind); rc = 1
if len(s) == len(p) and all(a["sha256"] == b["sha256"] for a, b in zip(s, p)):
    print("  ok   non-fork subagent system prompt is byte-identical on both builds")
    print("       sha256 %s (%d chars, %d prompt parts)" % (s[0]["sha256"][:16], s[0]["total_chars"], s[0]["n"]))
else:
    print("  FAIL captured prompts differ:")
    for kind, rs in (("stock", s), ("patched", p)):
        for r in rs:
            print("       %-7s sha256=%s chars=%d n=%d" % (kind, r["sha256"][:16], r["total_chars"], r["n"]))
    rc = 1
sys.exit(rc)
PY
[ $? = 0 ] || rc=1

[ -n "$S" ] || { echo "  FAIL stock subagent produced no parsable answer"; rc=1; }
[ "$S" = "$P" ] || { echo "  FAIL non-fork subagent answers differ between builds"; rc=1; }
echo "$P" | grep -q "FORK_CONTROL=NO" || { echo "  FAIL patched non-fork subagent reports <fork-control>"; rc=1; }
echo "$P" | grep -q "TASK_BLOCK=NO"   || { echo "  FAIL patched non-fork subagent reports a <TASK> block"; rc=1; }

[ $rc = 0 ] && echo "  ok  non-fork subagent unchanged by the patch (bytes + self-report agree)"
exit $rc
