#!/usr/bin/env bash
# T1: the stock installation is byte-identical to the pre-work baseline and
# `claude` still launches the unmodified Claude Code.
#
# Two tiers, on purpose:
#
#   HARD FAIL  any baseline file that is still present differs in size/mtime/
#              sha256; the pinned binary is missing or changed; the launcher
#              symlink points anywhere else; a file appeared inside the install
#              root that the baseline does not know; `claude` is not the stock
#              symlink or reports another version.
#
#   REPORTED   deltas that upstream's own native installer produces on startup
#              and that this repo cannot cause, because every script here only
#              ever READS the install root: old version files deleted by
#              `cleanupOldVersions` (it keeps the 2 newest unlocked versions,
#              VERSION_RETENTION_COUNT=2) and a refreshed symlink mtime from
#              re-installing the same target. These are printed, not failed --
#              hiding them would be dishonest, failing on them would blame the
#              patch for stock behaviour.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

BASE="$FFX_ROOT/baseline/stock-files.tsv"
[ -f "$BASE" ] || fail "baseline inventory missing"

rc=0
PINNED="$(stock_binary)"
ROOT="$(dirname "$(dirname "$PINNED")")"

while IFS=$'\t' read -r path size mtime hash; do
  [ "$path" = "path" ] && continue
  if [ "$size" = "symlink" ]; then
    got="-> $(readlink "$path")"
    [ "$got" = "$hash" ] || { echo "  FAIL symlink changed: $got != $hash"; rc=1; }
    gm="$(stat -c%Y "$path")"
    [ "$gm" = "$mtime" ] || echo "  note symlink re-created by upstream's installer (mtime $mtime -> $gm), same target"
    continue
  fi
  if [ ! -f "$path" ]; then
    if [ "$path" = "$PINNED" ]; then
      echo "  FAIL the pinned binary is gone: $path"; rc=1
    else
      echo "  note older version removed by upstream's cleanupOldVersions: $(basename "$path")"
    fi
    continue
  fi
  gs="$(stat -c%s "$path")"; gm="$(stat -c%Y "$path")"; gh="$(sha "$path")"
  [ "$gs" = "$size" ]  || { echo "  FAIL size changed:  $path"; rc=1; }
  [ "$gm" = "$mtime" ] || { echo "  FAIL mtime changed: $path"; rc=1; }
  [ "$gh" = "$hash" ]  || { echo "  FAIL sha256 changed: $path"; rc=1; }
done < "$BASE"

# nothing was ADDED to the stock install root (set comparison, not a count:
# upstream may delete old versions, but nobody may put files there)
while IFS= read -r f; do
  cut -f1 "$BASE" | grep -qxF "$f" \
    || { echo "  FAIL file not in the baseline appeared in the install root: $f"; rc=1; }
done < <(find "$ROOT" -type f)

# and the plain `claude` command still runs the stock build
ver="$(DISABLE_AUTOUPDATER=1 command claude --version 2>&1 | head -1 | tr -d '\r')"
[ "$ver" = "$(m upstream.version_string)" ] || { echo "  FAIL 'claude --version' = '$ver'"; rc=1; }
which_claude="$(command -v claude)"
[ "$which_claude" = "$(stock_symlink)" ] || { echo "  FAIL 'claude' resolves to $which_claude"; rc=1; }

echo "  stock: $which_claude -> $(readlink "$(stock_symlink)") ($ver)"
echo "  pinned binary sha256 $(sha "$PINNED") (as in the baseline)"
exit $rc
