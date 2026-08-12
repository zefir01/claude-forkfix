#!/usr/bin/env bash
# T11a: a changed upstream bundle must be rejected. No fuzz, no partial success.
#   (a) hash guard: a few changed bytes anywhere -> normalize refuses
#   (b) context guard: a changed line next to the patch target -> patch --fuzz=0
#       refuses, while a fuzzy apply would have succeeded (proof the strictness
#       is what saves us)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TARGET="$(m patch.target_basename)"
P="$FFX_ROOT/$(m patch.file)"
rc=0

python3 "$FFX_ROOT/scripts/extract-bundle.py" "$TMP/raw.js" >/dev/null || { echo "  FAIL extract"; exit 1; }

# (a) mutate 3 bytes inside the Z5 target line
python3 - "$TMP/raw.js" "$TMP/raw-bad.js" <<'PY'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
a = "St=d?.systemPrompt?d.systemPrompt:of(await _Eb(e,r,ie,Je)),"
s = s.replace(a, a.replace("_Eb(e,r,ie,Je)", "_Eb(e,r,ie,JX)"), 1)
open(sys.argv[2], 'w', encoding='utf-8').write(s)
PY
out="$(python3 "$FFX_ROOT/scripts/normalize-bundle.py" "$TMP/raw-bad.js" "$TMP/x.js" 2>&1)"
if [ $? -eq 0 ]; then echo "  FAIL mutated bundle accepted by normalize"; rc=1
else
  echo "$out" | grep -q "INCOMPATIBLE WITH CURRENT CLAUDE VERSION" \
    || { echo "  FAIL wrong error for mutated bundle: $out"; rc=1; }
  echo "  (a) mutated target line -> refused"
fi

# (b) mutate a context line, then bypass the hash guard and try to patch
python3 "$FFX_ROOT/scripts/normalize-bundle.py" "$TMP/raw.js" "$TMP/$TARGET" >/dev/null
python3 - "$TMP/$TARGET" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
a = "Je=Array.from(U.additionalWorkingDirectories.keys()),"
assert s.count(a) == 1
s = s.replace(a, "Je=Array.from(U.additionalWorkingDirectories.keys() ),", 1)
open(p, 'w', encoding='utf-8').write(s)
PY
cp "$TMP/$TARGET" "$TMP/fuzzy-$TARGET"
patch -p1 --fuzz=0 --dry-run -d "$TMP" < "$P" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo "  FAIL patch --fuzz=0 accepted a changed context line"; rc=1
else echo "  (b) changed context line -> patch --fuzz=0 refused"; fi

# same file, fuzzy: would have silently "worked" -> this is what we forbid
mkdir -p "$TMP/fuzzy" && mv "$TMP/fuzzy-$TARGET" "$TMP/fuzzy/$TARGET"
patch -p1 --fuzz=2 -l --dry-run -d "$TMP/fuzzy" < "$P" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo "  (b) confirmed: a fuzzy apply would have succeeded"; fi

exit $rc
