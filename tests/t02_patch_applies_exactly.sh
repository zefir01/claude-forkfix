#!/usr/bin/env bash
# T-auto: version guard + source-hash guard + exact patch application, from
# scratch, in a temp dir. Reproduces the pinned patched bytes.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TARGET="$(m patch.target_basename)"

python3 "$FFX_ROOT/scripts/extract-bundle.py" "$TMP/raw.js" >/dev/null
python3 "$FFX_ROOT/scripts/normalize-bundle.py" "$TMP/raw.js" "$TMP/$TARGET" >/dev/null
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$TMP" < "$FFX_ROOT/$(m patch.file)" >/dev/null

got="$(sha "$TMP/$TARGET")"
want="$(m patch.patched_sha256)"
[ "$got" = "$want" ] || { echo "  FAIL patched sha256 $got != $want"; exit 1; }
echo "  reproduced patched $TARGET: $got"
