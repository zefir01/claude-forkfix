#!/usr/bin/env bash
# Report-only compatibility check. Modifies nothing (temp dir only).
# Exit 0 = the pinned patch still matches the installed Claude Code.
# Exit 1 = incompatible; the patched launcher will refuse to run.
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="$(stock_binary)"
LINK="$(stock_symlink)"
TARGET="$(m patch.target_basename)"
TREE="$FFX_ROOT/build/tree/$TARGET"
OK=0
row() { printf '%-34s %s\n' "$1" "$2"; }
bad() { OK=1; }

echo "claude-forkfix compatibility check  ($(m patch_name))"
echo

row "stock launcher" "$LINK"
if [ -e "$LINK" ]; then row "  resolves to" "$(readlink -f "$LINK")"; else row "  resolves to" "MISSING"; bad; fi
row "expected stock binary" "$BIN"
if [ -f "$BIN" ]; then
  VER="$(DISABLE_AUTOUPDATER=1 "$BIN" --version 2>/dev/null | head -1 | tr -d '\r')"
else
  VER="MISSING"; bad
fi
row "upstream version (reported)" "$VER"
row "upstream version (expected)" "$(m upstream.version_string)"
[ "$VER" = "$(m upstream.version_string)" ] || bad
if [ -e "$LINK" ] && [ -f "$BIN" ] && [ "$(readlink -f "$LINK")" != "$(readlink -f "$BIN")" ]; then
  row "selected version" "MISMATCH (stock 'claude' is not the pinned version)"; bad
fi
echo

if [ -f "$BIN" ]; then GOT="$(sha "$BIN")"; else GOT="-"; fi
row "stock binary sha256" "$GOT"
row "  expected" "$(m upstream.binary_sha256)"
[ "$GOT" = "$(m upstream.binary_sha256)" ] || bad

if python3 "$FFX_ROOT/scripts/extract-bundle.py" "$TMP/raw.js" >/dev/null 2>&1; then
  row "embedded bundle sha256" "$(sha "$TMP/raw.js") (as pinned)"
else
  row "embedded bundle sha256" "MISMATCH / unreadable"; bad
fi
row "  expected" "$(m bundle.extracted_sha256)"

if [ -f "$TMP/raw.js" ] && python3 "$FFX_ROOT/scripts/normalize-bundle.py" "$TMP/raw.js" "$TMP/cli.js" >/dev/null 2>&1; then
  row "normalized bundle sha256" "$(sha "$TMP/cli.js") (as pinned)"
else
  row "normalized bundle sha256" "MISMATCH / anchors not found"; bad
fi
row "  expected" "$(m normalize.normalized_sha256)"
echo

row "patch file" "$(m patch.file)"
row "  sha256" "$(sha "$FFX_ROOT/$(m patch.file)")"
row "  expected" "$(m patch.sha256)"
[ "$(sha "$FFX_ROOT/$(m patch.file)")" = "$(m patch.sha256)" ] || bad
if [ -f "$TMP/cli.js" ] && patch -p1 --fuzz=0 --dry-run -d "$TMP" < "$FFX_ROOT/$(m patch.file)" >/dev/null 2>&1; then
  row "patch applies (--fuzz=0)" "yes"
else
  row "patch applies (--fuzz=0)" "NO"; bad
fi
row "expected patched sha256" "$(m patch.patched_sha256)"
echo

if [ -f "$TREE" ]; then
  GOT="$(sha "$TREE")"
  if [ "$GOT" = "$(m patch.patched_sha256)" ]; then
    row "patched tree" "built and matches ($TREE)"
  else
    row "patched tree" "PRESENT BUT sha256 $GOT != expected"; bad
  fi
else
  row "patched tree" "not built (run scripts/prepare-patched.sh)"
fi
if [ -x "$FFX_ROOT/$(m runtime.bun_path)" ]; then
  row "private bun runtime" "$(m runtime.bun_version) present"
else
  row "private bun runtime" "MISSING"; bad
fi
echo

if [ "$OK" -eq 0 ]; then
  echo "PATCH COMPATIBLE: yes"
else
  echo "PATCH COMPATIBLE: no"
  echo "INCOMPATIBLE WITH CURRENT CLAUDE VERSION"
fi
exit "$OK"
