#!/usr/bin/env python3
"""Whitespace-only normalization of the extracted bundle.

The upstream bundle is minified: the two lines we care about are 1.7 KB and
22 KB long. A unified diff against them would be unreadable, which defeats the
purpose of shipping a human-readable patch.

So before patching we insert newlines at a fixed list of pinned anchor strings.
This step is:

  * whitespace-only        -- the only edit is inserting "\\n"
  * exact-match, no fuzz   -- each anchor must occur EXACTLY once
  * provably inert         -- each anchor must be preceded by one of , ; { }
                              (a newline after any of those is not a token
                              boundary change and cannot trigger ASI)
  * verified               -- output-without-newlines must equal
                              input-without-newlines, and the resulting file
                              SHA-256 is pinned in manifest.json

Any deviation is a hard failure.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SAFE_PREV = ",;{}"


def die(msg):
    print("INCOMPATIBLE WITH CURRENT CLAUDE VERSION", file=sys.stderr)
    print("reason: " + msg, file=sys.stderr)
    sys.exit(1)


def main():
    with open(os.path.join(ROOT, "manifest.json")) as f:
        m = json.load(f)

    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "cli-extract-raw.js")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "build", "cli-normalized.js")
    check_hash = "--no-hash-check" not in sys.argv

    with open(src, encoding="utf-8") as f:
        text = f.read()

    anchors = m["normalize"]["split_before"]
    for a in anchors:
        n = text.count(a)
        if n != 1:
            die("split anchor occurs %d times (expected exactly 1): %r" % (n, a[:70]))
        i = text.index(a)
        if i == 0 or text[i - 1] not in SAFE_PREV:
            die("split anchor is not preceded by one of %r: %r" % (SAFE_PREV, a[:70]))
        text = text[:i] + "\n" + text[i:]

    with open(src, encoding="utf-8") as f:
        original = f.read()
    if text.replace("\n", "") != original.replace("\n", ""):
        die("normalization changed more than whitespace")
    if text.count("\n") != original.count("\n") + len(anchors):
        die("normalization inserted the wrong number of newlines")

    data = text.encode("utf-8")
    got = hashlib.sha256(data).hexdigest()
    if check_hash and got != m["normalize"]["normalized_sha256"]:
        die("normalized bundle SHA-256 %s != expected %s" % (got, m["normalize"]["normalized_sha256"]))

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(data)
    print("normalized (+%d newlines) -> %s" % (len(anchors), dst))
    print("sha256 %s" % got)


if __name__ == "__main__":
    main()
