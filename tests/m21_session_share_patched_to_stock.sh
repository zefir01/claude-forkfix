#!/usr/bin/env bash
# T3: a session created and continued by claude-forkfix resumes under STOCK claude.
# Also checks scenario C: both sessions live in the same shared project directory,
# so the resumable-session list is one list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

WORK="${FFX_WORK:-/tmp/ffx-session-test}"
mkdir -p "$WORK"; cd "$WORK"
SID="$(cat /proc/sys/kernel/random/uuid)"
SLUG="$HOME/.claude/projects/$(echo "$WORK" | sed 's#/#-#g')"
rc=0

echo "  session $SID   cwd $WORK"
out="$("$FFX_ROOT/bin/claude-forkfix" -p --session-id "$SID" \
  "Remember this marker for later: MEMORY_MARKER_67890. Reply with just OK." 2>&1)"
echo "  patched wrote: ${out:0:60}"
[ -f "$SLUG/$SID.jsonl" ] || { echo "  FAIL transcript not at $SLUG/$SID.jsonl"; rc=1; }

out="$(DISABLE_AUTOUPDATER=1 command claude -p --resume "$SID" \
  "What marker did I ask you to remember? Reply with only the marker string." 2>&1)"
echo "  stock   read: ${out:0:60}"
echo "$out" | grep -q "MEMORY_MARKER_67890" || { echo "  FAIL stock build did not recover the marker"; rc=1; }

# scenario C: shared resumable-session list
if [ -f "$WORK/.last-stock-session" ]; then
  prev="$(cat "$WORK/.last-stock-session")"
  [ -f "$SLUG/$prev.jsonl" ] && [ -f "$SLUG/$SID.jsonl" ] \
    && echo "  shared list: both $prev (stock-created) and $SID (patched-created) in $SLUG" \
    || { echo "  FAIL sessions not in one shared directory"; rc=1; }
fi
exit $rc
