#!/usr/bin/env bash
# Mechanism test (differential, stock vs patched) -- RUNTIME CAPTURE, not model
# self-report: what exactly is handed to the API as the fork's system prompt?
#
# Both builds are instrumented identically by scripts/make-debug-tree.py, which
# wraps the two `systemPrompt:Ut` sites in Z5 -- i.e. the value that becomes the
# query loop's `systemPrompt` and is reused for every turn of that agent. The
# instrumentation is diagnostic-only, is not part of patches/, and is a no-op
# unless FFX_DEBUG_FILE is set.
#
#   unpatched bundle -> the fork's system prompt is the parent's, verbatim:
#                       no <fork-control>, no <TASK>
#   patched tree     -> the parent's prompt + <fork-control>, and <TASK> holds
#                       the directive string byte for byte
#
# An earlier version of this test asked the worker to describe its own prompt.
# That is unreliable in both directions (a worker answered NO_TASK_BLOCK while
# the block was demonstrably present, and vice versa), so the assertion is now
# on the captured bytes. The model is only used to make a fork happen at all.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

BUN="$FFX_ROOT/$(m runtime.bun_path)"
DBG="$FFX_ROOT/build/debug"
TREE="$FFX_ROOT/build/tree/$(m patch.target_basename)"
NORM="$FFX_ROOT/build/cli-normalized.js"
rc=0

[ -f "$TREE" ] || fail "patched tree missing; run scripts/prepare-patched.sh"
[ -f "$NORM" ] || fail "normalized bundle missing; run scripts/prepare-patched.sh"
mkdir -p "$DBG"
python3 "$FFX_ROOT/scripts/make-debug-tree.py" "$TREE" "$DBG/patched-cli.js" >/dev/null || fail "instrumenting patched tree"
python3 "$FFX_ROOT/scripts/make-debug-tree.py" "$NORM" "$DBG/stock-cli.js"   >/dev/null || fail "instrumenting unpatched bundle"

DIRECTIVE='FFX_M22_MARKER_7788: Write a file named m22.txt containing exactly one line: ok. Then report the path and stop. END_OF_DIRECTIVE_9911'
PROMPT="Call the Agent tool once with subagent_type \"fork\" and exactly this prompt, passed through character for character:

$DIRECTIVE

When the worker reports back, reply with exactly: DONE"

capture() { # $1 = stock|patched ; prints the capture file path
  local kind="$1" work="/tmp/ffx-m22-$1" cap="/tmp/ffx-m22-$1.jsonl"
  rm -rf "$work" "$cap"; mkdir -p "$work"
  ( cd "$work" && FFX_DEBUG_FILE="$cap" DISABLE_AUTOUPDATER=1 \
      "$BUN" "$DBG/$kind-cli.js" -p --permission-mode bypassPermissions \
      --strict-mcp-config "$PROMPT" >"$work/out.txt" 2>"$work/err.txt" )
  echo "$cap"
}

check() { # $1 = stock|patched ; $2 = capture path
  python3 - "$1" "$2" "$DIRECTIVE" <<'PY'
import json, sys
kind, path, directive = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
try:
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.strip()
        if line:
            rows.append(json.loads(line))
except FileNotFoundError:
    print("  FAIL %-7s no runtime capture produced (agent never started?)" % kind)
    sys.exit(1)
rc = 0
fc = [r for r in rows if r.get("has_fork_control")]
tk = [r for r in rows if r.get("has_TASK")]
print("  %-7s %d system prompts captured, %d with <fork-control>, %d with <TASK>"
      % (kind, len(rows), len(fc), len(tk)))
if not rows:
    print("  FAIL %-7s capture file is empty" % kind); sys.exit(1)
if kind == "stock":
    if fc or tk:
        print("  FAIL stock build carries fork-control -- the unpatched bundle is not unpatched"); rc = 1
    else:
        print("  ok   unpatched: nothing about the assignment exists at system level")
else:
    if not fc:
        print("  FAIL patched build produced no <fork-control> in any system prompt"); rc = 1
    exact = [r for r in tk if r.get("task") == directive]
    if not exact:
        got = [r.get("task") for r in tk][:1]
        print("  FAIL patched <TASK> body is not the directive byte for byte: %r" % (got,)); rc = 1
    else:
        print("  ok   patched: <TASK> == the spawn directive, byte for byte (%d chars)"
              % len(directive))
    # the parent's own prompt must survive untouched in front of the block
    for r in fc:
        if r["total_chars"] <= len(r["fork_control"]):
            print("  FAIL patched fork prompt is only the block; parent prompt lost"); rc = 1
            break
    else:
        print("  ok   patched: parent prompt still present, block only appended")
    # the em dashes in the block must be real U+2014 at runtime; the diagnostic
    # dump file itself double-encodes them, which is a property of the dump, not
    # of what the API receives -- assert on the runtime codepoints
    for r in fc:
        if r.get("nonascii") and r["nonascii"][0] != 0x2014:
            print("  FAIL runtime fork-control text is mis-encoded: %r" % (r["nonascii"],)); rc = 1
            break
    else:
        print("  ok   patched: block text is well-formed UTF-8 at runtime (U+2014)")
sys.exit(rc)
PY
}

for kind in stock patched; do
  cap="$(capture "$kind")"
  check "$kind" "$cap" || rc=1
  f="/tmp/ffx-m22-$kind/m22.txt"
  [ -f "$f" ] && echo "  $kind: the fork really ran (m22.txt written)" \
              || echo "  note: $kind fork produced no m22.txt (capture assertions still apply)"
done

[ $rc = 0 ] && echo "  ok  fork assignment reaches the API in the system prompt on patched, absent on unpatched"
exit $rc
