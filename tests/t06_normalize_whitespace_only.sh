#!/usr/bin/env bash
# T-auto: prove the normalization step is whitespace-only and unambiguous.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 "$FFX_ROOT/scripts/extract-bundle.py" "$TMP/raw.js" >/dev/null
python3 "$FFX_ROOT/scripts/normalize-bundle.py" "$TMP/raw.js" "$TMP/cli.js" >/dev/null

python3 - "$FFX_ROOT/manifest.json" "$TMP/raw.js" "$TMP/cli.js" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
raw = open(sys.argv[2], encoding='utf-8').read()
norm = open(sys.argv[3], encoding='utf-8').read()
anchors = m['normalize']['split_before']
errs = []
if raw.replace('\n', '') != norm.replace('\n', ''):
    errs.append("normalized file differs by more than newlines")
if norm.count('\n') != raw.count('\n') + len(anchors):
    errs.append("wrong number of inserted newlines")
for a in anchors:
    if raw.count(a) != 1:
        errs.append("anchor not unique: %r" % a[:50])
        continue
    i = raw.index(a)
    if raw[i-1] not in ',;{}':
        errs.append("unsafe split boundary before %r (prev=%r)" % (a[:40], raw[i-1]))
    if not norm[:norm.index(a)].endswith('\n'):
        errs.append("newline not inserted before %r" % a[:40])
for e in errs:
    print("  FAIL " + e)
print("  %d anchors, all unique, all on , ; { } boundaries; +%d newlines only"
      % (len(anchors), len(anchors)))
sys.exit(1 if errs else 0)
PY
