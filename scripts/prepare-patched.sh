#!/usr/bin/env bash
# Build the patched runtime tree from: stock installation + patches/*.patch.
#
# The stock installation is only ever READ (one byte-range read + --version).
# Everything this script writes goes to build/, which is disposable.
#
# Any deviation from manifest.json is a hard failure:
#   INCOMPATIBLE WITH CURRENT CLAUDE VERSION + nonzero exit. Never auto-repaired.
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BIN="$(stock_binary)"
TREE="$FFX_ROOT/build/tree"
TARGET="$(m patch.target_basename)"
BUN="$FFX_ROOT/$(m runtime.bun_path)"
PATCH_FILE="$FFX_ROOT/$(m patch.file)"
WANT_VER="$(m upstream.version_string)"

echo "== 1. stock installation"
[ -f "$BIN" ] || incompatible "stock binary not found: $BIN"
require_pinned_stock_selected
VER="$(DISABLE_AUTOUPDATER=1 "$BIN" --version 2>/dev/null | head -1 | tr -d '\r')"
[ "$VER" = "$WANT_VER" ] || incompatible "stock reports '$VER', manifest expects '$WANT_VER'"
echo "   binary : $BIN"
echo "   version: $VER"

echo "== 2. extract the embedded JS bundle (read-only)"
python3 "$FFX_ROOT/scripts/extract-bundle.py" "$FFX_ROOT/build/cli-extract-raw.js"

echo "== 3. normalize (whitespace-only line splitting)"
python3 "$FFX_ROOT/scripts/normalize-bundle.py" \
  "$FFX_ROOT/build/cli-extract-raw.js" "$FFX_ROOT/build/cli-normalized.js"

echo "== 4. apply $(m patch.file) with patch --fuzz=0"
rm -rf "$TREE"
mkdir -p "$TREE"
cp "$FFX_ROOT/build/cli-normalized.js" "$TREE/$TARGET"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$TREE" < "$PATCH_FILE" \
  || incompatible "patch did not apply exactly (--fuzz=0)"

echo "== 5. verify patched bytes"
GOT="$(sha "$TREE/$TARGET")"
WANT="$(m patch.patched_sha256)"
[ "$GOT" = "$WANT" ] || incompatible "patched $TARGET sha256 $GOT != expected $WANT"
echo "   sha256 $GOT (as pinned)"

echo "== 6. verify private runtime"
[ -x "$BUN" ] || fail "private bun runtime missing: $BUN"
GOT="$(sha "$BUN")"
WANT="$(m runtime.bun_sha256)"
[ "$GOT" = "$WANT" ] || fail "bun sha256 $GOT != expected $WANT"
echo "   bun $(m runtime.bun_version) ok"

echo "== 7. smoke test"
OUT="$(DISABLE_AUTOUPDATER=1 "$BUN" "$TREE/$TARGET" --version 2>&1 | head -1 | tr -d '\r')"
[ "$OUT" = "$WANT_VER" ] || fail "patched tree reports '$OUT', expected '$WANT_VER'"
echo "   patched tree reports: $OUT"

python3 - "$FFX_ROOT" "$TREE/$TARGET" "$PATCH_FILE" "$BIN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY' > "$TREE/.forkfix-build.json"
import hashlib, json, sys
root, target, patch, binary, when = sys.argv[1:6]
def h(p):
    x = hashlib.sha256()
    with open(p, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''): x.update(c)
    return x.hexdigest()
print(json.dumps({
    "built_at": when,
    "built_from_stock_binary": binary,
    "stock_binary_sha256": h(binary),
    "patch_file": patch,
    "patch_sha256": h(patch),
    "patched_target_sha256": h(target),
}, indent=2))
PY

echo
echo "OK  patched tree: $TREE/$TARGET"
echo "OK  launch with : $FFX_ROOT/bin/claude-forkfix"
