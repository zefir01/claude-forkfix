#!/usr/bin/env bash
# T2: a session created by STOCK claude resumes under claude-forkfix.
# No export, no copy, no separate HOME/CLAUDE_CONFIG_DIR: same ~/.claude.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

WORK="${FFX_WORK:-/tmp/ffx-session-test}"
mkdir -p "$WORK"; cd "$WORK"
SID="$(cat /proc/sys/kernel/random/uuid)"
SLUG="$HOME/.claude/projects/$(echo "$WORK" | sed 's#/#-#g')"
rc=0

echo "  session $SID   cwd $WORK"
out="$(DISABLE_AUTOUPDATER=1 command claude -p --session-id "$SID" \
  "Remember this marker for later: MEMORY_MARKER_12345. Reply with just OK." 2>&1)"
echo "  stock  wrote: ${out:0:60}"
[ -f "$SLUG/$SID.jsonl" ] || { echo "  FAIL transcript not at $SLUG/$SID.jsonl"; rc=1; }
before="$(stat -c%s "$SLUG/$SID.jsonl" 2>/dev/null || echo 0)"

out="$("$FFX_ROOT/bin/claude-forkfix" -p --resume "$SID" \
  "What marker did I ask you to remember? Reply with only the marker string." 2>&1)"
echo "  patched read: ${out:0:60}"
echo "$out" | grep -q "MEMORY_MARKER_12345" || { echo "  FAIL patched build did not recover the marker"; rc=1; }

after="$(stat -c%s "$SLUG/$SID.jsonl")"
[ "$after" -gt "$before" ] || { echo "  FAIL patched build did not append to the same transcript"; rc=1; }
echo "  same transcript file grew $before -> $after bytes"

# no alternative storage was created
for d in "$HOME/.claude-forkfix" "$FFX_ROOT/.claude" "$FFX_ROOT/home"; do
  [ -e "$d" ] && { echo "  FAIL alternative storage: $d"; rc=1; }
done
echo "$SID" > "$WORK/.last-stock-session"
exit $rc
