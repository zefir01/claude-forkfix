#!/usr/bin/env bash
# T-auto: patch state detection. Applying the patch to an already-patched file
# must FAIL (no double application, no silent success), and the patched state
# must be detectable via a reverse dry-run.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TARGET="$(m patch.target_basename)"
P="$FFX_ROOT/$(m patch.file)"

cp "$FFX_ROOT/build/cli-normalized.js" "$TMP/$TARGET" 2>/dev/null \
  || { python3 "$FFX_ROOT/scripts/extract-bundle.py" "$TMP/raw.js" >/dev/null; \
       python3 "$FFX_ROOT/scripts/normalize-bundle.py" "$TMP/raw.js" "$TMP/$TARGET" >/dev/null; }

patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$TMP" < "$P" >/dev/null 2>&1
[ $? -eq 0 ] || { echo "  FAIL first application failed"; exit 1; }

patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$TMP" < "$P" >/dev/null 2>&1
[ $? -ne 0 ] || { echo "  FAIL second application succeeded (not idempotent-safe)"; exit 1; }
echo "  re-applying the patch is refused"

patch -p1 --fuzz=0 -R --dry-run -d "$TMP" < "$P" >/dev/null 2>&1
[ $? -eq 0 ] || { echo "  FAIL patched state not detectable (reverse dry-run failed)"; exit 1; }
echo "  patched state detectable via reverse dry-run"

# and the double-application attempt left the file unchanged
got="$(sha "$TMP/$TARGET")"
[ "$got" = "$(m patch.patched_sha256)" ] || { echo "  FAIL file mutated by the refused attempt"; exit 1; }
