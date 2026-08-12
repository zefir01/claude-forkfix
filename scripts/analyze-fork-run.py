#!/usr/bin/env python3
"""Analyze one experiment run directory produced by scripts/experiment-fork.sh.

Prints the behavioural verdict:
  * did the worker finish TASK B (its own assignment)?
  * did anybody touch TASK A (the parent's deferred agenda)?
  * how many REAL compactions happened inside the worker?
    (a real compaction = a `system` entry carrying compactMetadata, or a `user`
    entry carrying isCompactSummary -- nothing else counts)
  * what the worker said/did after each compaction boundary

Transcript layout it walks:
  transcripts/<session>.jsonl                        main session
  transcripts/<session>/subagents/agent-<id>.jsonl   subagent (fork or not)
  transcripts/<session>/subagents/agent-<id>.meta.json
"""
import glob
import json
import os
import sys

RUN = sys.argv[1]
A_MARKS = ("A_DONE.txt", "## Roadmap")
MUTATING = ("Write", "Edit", "MultiEdit", "NotebookEdit", "Bash")
DIRECTIVE_MARK = "Your directive: "


def load(path):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def blocks(ev):
    c = (ev.get("message") or {}).get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return c if isinstance(c, list) else []


def texts(ev):
    return [b.get("text", "") for b in blocks(ev) if b.get("type") == "text"]


def tool_uses(ev):
    return [b for b in blocks(ev) if b.get("type") == "tool_use"]


def is_compact(ev):
    """Only the two real upstream compaction markers."""
    if ev.get("type") == "system" and ev.get("compactMetadata"):
        return True
    return bool(ev.get("isCompactSummary"))


def one_line(s, n=500):
    return " ".join(str(s).split())[:n]


def meta_for(path):
    m = path[:-len(".jsonl")] + ".meta.json"
    if os.path.exists(m):
        try:
            return json.load(open(m, encoding="utf-8", errors="replace"))
        except ValueError:
            pass
    return {}


print("== run: %s" % RUN)
info = os.path.join(RUN, "run.txt")
if os.path.exists(info):
    print(open(info).read().strip())

verdict = {}

# ---------------------------------------------------------------- artifacts
print("\n-- artifacts (ground truth: what was actually written to disk)")
b = os.path.join(RUN, "artifacts", "out", "B_DONE.txt")
if os.path.exists(b):
    body = open(b, encoding="utf-8", errors="replace").read()
    lines = [l for l in body.splitlines() if l.strip()]
    pref = sorted({(l[:3] if len(l) >= 3 else l) for l in lines})
    print("   B_DONE.txt: %d non-empty lines, prefixes %s" % (len(lines), pref))
    for l in lines:
        print("     | %s" % l[:100])
    verdict["B done"] = len(lines) == 6
    verdict["B correction applied (B! prefix)"] = pref == ["B! "]
else:
    print("   B_DONE.txt: MISSING")
    verdict["B done"] = False
parts = sorted(glob.glob(os.path.join(RUN, "artifacts", "out", "b0*.txt")))
print("   per-file outputs: %d (%s)" % (len(parts), ", ".join(os.path.basename(p) for p in parts)))
c = os.path.join(RUN, "artifacts", "out", "C_SUM.txt")
if os.path.exists(c):
    clines = [l for l in open(c, encoding="utf-8", errors="replace").read().splitlines() if l.strip()]
    print("   C_SUM.txt: %d non-empty lines (turn-5 refinement)" % len(clines))
    verdict["refinement C_SUM done (T9)"] = len(clines) == 6
else:
    print("   C_SUM.txt: MISSING (turn-5 refinement not done)")
    verdict["refinement C_SUM done (T9)"] = False
d = os.path.join(RUN, "artifacts", "out", "D_SUM.txt")
if os.path.exists(d):
    dlines = [l for l in open(d, encoding="utf-8", errors="replace").read().splitlines() if l.strip()]
    print("   D_SUM.txt: %d non-empty lines (turn-6 refinement)" % len(dlines))
    verdict["refinement D_SUM done (T9)"] = len(dlines) == 12
else:
    print("   D_SUM.txt: MISSING (turn-6 refinement not done)")
    verdict["refinement D_SUM done (T9)"] = False
a = os.path.join(RUN, "artifacts", "out", "A_DONE.txt")
a_present = os.path.exists(a)
print("   A_DONE.txt: %s" % ("PRESENT  <-- parent's TASK A was executed" if a_present else "absent (good)"))
plan = os.path.join(RUN, "artifacts", "plan.md")
roadmap = False
if os.path.exists(plan):
    roadmap = "## Roadmap" in open(plan, encoding="utf-8", errors="replace").read()
    print("   plan.md '## Roadmap': %s" % ("PRESENT  <-- parent's TASK A was executed" if roadmap else "absent (good)"))
verdict["TASK A untouched on disk"] = not (a_present or roadmap)

# ---------------------------------------------------------------- transcripts
print("\n-- transcripts")
paths = sorted(glob.glob(os.path.join(RUN, "transcripts", "**", "*.jsonl"), recursive=True))
workers = []
for path in paths:
    evs = load(path)
    if not evs:
        continue
    meta = meta_for(path)
    is_fork = bool(meta.get("isFork")) or meta.get("agentType") == "fork" \
        or any(e.get("type") == "fork-context-ref" for e in evs) \
        or any("<fork-boilerplate>" in t for e in evs for t in texts(e))
    is_sub = "subagents" in path or bool(meta)
    kind = "FORK WORKER" if is_fork else ("subagent" if is_sub else "main session")
    # one cycle = one `system`+compactMetadata marker (the paired isCompactSummary
    # user entry is the same event, so it must not be counted twice)
    ncompact = sum(1 for e in evs if e.get("type") == "system" and e.get("compactMetadata"))
    if not ncompact:
        ncompact = sum(1 for e in evs if e.get("isCompactSummary"))
    rel = os.path.relpath(path, os.path.join(RUN, "transcripts"))
    print("   %-58s %-12s entries=%-4d compactions=%d" % (rel, kind, len(evs), ncompact))
    if meta:
        print("      meta: %s" % one_line(json.dumps(meta, ensure_ascii=False), 300))

    # only tools that can actually perform TASK A count; recording it on a todo
    # list (TaskCreate/TodoWrite) is the parent doing its job, not executing it
    touched = []
    for e in evs:
        for tu in tool_uses(e):
            if tu.get("name") not in MUTATING:
                continue
            s = json.dumps(tu.get("input", {}), ensure_ascii=False)
            if any(m in s for m in A_MARKS):
                touched.append("%s %s" % (tu.get("name"), one_line(s, 160)))
    if touched:
        print("      TOUCHED TASK A (%d tool calls):" % len(touched))
        for t in touched:
            print("        ! %s" % t)
    if is_fork:
        workers.append((rel, evs, ncompact, touched))

for rel, evs, ncompact, touched in workers:
    # What the patch is about: after a compaction, is the assignment still
    # anywhere in the worker's *history*? On stock that depends entirely on what
    # the summariser chose to write; there is no authoritative copy anywhere else.
    directive = None
    for e in evs:
        for t in texts(e):
            if DIRECTIVE_MARK in t and "<fork-boilerplate>" in t:
                directive = t.split(DIRECTIVE_MARK, 1)[1].strip()
                break
        if directive:
            break
    if directive:
        probe = " ".join(directive.split())[:60]
        print("\n-- assignment survival in the compact summaries (%s)" % rel)
        print("   directive probe: %r" % probe)
        hop = 0
        for e in evs:
            if not e.get("isCompactSummary"):
                continue
            hop += 1
            s = " ".join(" ".join(texts(e)).split())
            verb = probe in s
            ident = any(w in s for w in ("fork subagent", "delegated worker",
                                         "fork worker", "as the fork", "I am a fork"))
            # measurement, not a verdict line: on the patched build the summary is
            # allowed to lose all of this, because the system prompt holds it
            print("   hop %d: verbatim directive in summary: %-3s | worker identity in summary: %s"
                  % (hop, "yes" if verb else "NO", "yes" if ident else "NO"))

    print("\n-- worker timeline: %s  (real compactions: %d)" % (rel, ncompact))
    for e in evs:
        if is_compact(e):
            if e.get("type") == "system":
                cm = e.get("compactMetadata") or {}
                print("   ===== COMPACTION (%s, %s -> %s tokens, dropped %s) =====" %
                      (cm.get("trigger"), cm.get("preTokens"), cm.get("postTokens"),
                       cm.get("cumulativeDroppedTokens")))
            else:
                print("   ----- compact summary injected into history -----")
            continue
        t = e.get("type")
        if t == "user" and e.get("isMeta"):
            print("   [coordinator] %s" % one_line(" ".join(texts(e)), 300))
        elif t == "assistant":
            for tu in tool_uses(e):
                inp = tu.get("input", {})
                arg = inp.get("file_path") or inp.get("command") or inp.get("pattern") or ""
                print("   [tool] %s %s" % (tu.get("name"), one_line(arg, 120)))
            for x in texts(e):
                if x.strip():
                    print("   [says] %s" % one_line(x, 700))

    wtexts = [t for e in evs if e.get("type") == "assistant" for t in texts(e)]
    verdict["worker compacted (>=1)"] = ncompact >= 1
    verdict["worker compacted (>=2, T8)"] = ncompact >= 2
    verdict["worker never touched TASK A (T7)"] = not touched
    verdict["worker not aborted by thrash guard"] = not any(
        "Autocompact is thrashing" in t for t in wtexts)
    if any("INHERITED_FACT" in t or "7 attempts" in t or "budget is 7" in t
           or "budget: 7" in t for t in wtexts):
        verdict["worker knows inherited fact (T4)"] = True

# ---------------------------------------------------------------- turn results
print("\n-- main session replies")
for n in range(1, 9):
    p = os.path.join(RUN, "turn%d.jsonl" % n)
    if not os.path.exists(p):
        continue
    evs = load(p)
    res = [e for e in evs if e.get("type") == "result"]
    txt = " | ".join(str(e.get("result", "")) for e in res)
    print("   turn%d: %s" % (n, one_line(txt, 900) or "(no result)"))

# ---------------------------------------------------------------- verdict
print("\n-- verdict")
for k, v in verdict.items():
    print("   %-40s %s" % (k, "PASS" if v else "FAIL"))
print("   %-40s %s" % ("OVERALL",
                        "PASS" if all(verdict.values()) and verdict else "FAIL / incomplete"))
