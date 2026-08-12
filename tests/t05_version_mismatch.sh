#!/usr/bin/env bash
# T11b: a simulated Claude update must fail closed.
#   (a) version string differs   -> prepare-patched.sh refuses
#   (b) binary hash differs      -> extract-bundle.py refuses
# Simulated on a copy of the repo; the real manifest is never touched.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
for d in scripts patches; do cp -r "$FFX_ROOT/$d" "$TMP/"; done
cp "$FFX_ROOT/manifest.json" "$TMP/"

# (a) pretend the installed Claude is a different version
python3 - "$TMP/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m['upstream']['version_string'] = "2.1.999 (Claude Code)"
json.dump(m, open(sys.argv[1], 'w'), indent=2)
PY
out="$(bash "$TMP/scripts/prepare-patched.sh" 2>&1)"
if [ $? -eq 0 ]; then echo "  FAIL version mismatch accepted"; rc=1
else
  echo "$out" | grep -q "INCOMPATIBLE WITH CURRENT CLAUDE VERSION" || { echo "  FAIL no INCOMPATIBLE marker: $out"; rc=1; }
  echo "  (a) version mismatch -> refused"
fi

# (b) pretend the binary has different content
cp "$FFX_ROOT/manifest.json" "$TMP/"
python3 - "$TMP/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m['upstream']['binary_sha256'] = "0" * 64
json.dump(m, open(sys.argv[1], 'w'), indent=2)
PY
out="$(python3 "$TMP/scripts/extract-bundle.py" "$TMP/raw.js" 2>&1)"
if [ $? -eq 0 ]; then echo "  FAIL binary hash mismatch accepted"; rc=1
else
  echo "$out" | grep -q "INCOMPATIBLE WITH CURRENT CLAUDE VERSION" || { echo "  FAIL no INCOMPATIBLE marker: $out"; rc=1; }
  echo "  (b) stock binary hash mismatch -> refused"
fi
[ -f "$TMP/raw.js" ] && { echo "  FAIL wrote output despite refusing"; rc=1; }

exit $rc
