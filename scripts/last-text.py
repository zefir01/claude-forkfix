#!/usr/bin/env python3
"""Print the final assistant/result text of a stream-json run log."""
import json
import sys

out = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "result":
        out.append(str(ev.get("result", "")))
print(" ".join(out).replace("\n", " | ") if out else "(no result event)")
