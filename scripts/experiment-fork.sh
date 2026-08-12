#!/usr/bin/env bash
# Fork identity/assignment experiment (T4-T9).
#
#   scripts/experiment-fork.sh <stock|patched> <label> [pct] [window]
#
# One shared session, eight headless turns:
#   turn 1  MAIN records TASK A as its OWN unfinished TODO (TodoWrite) and reads
#           the six docs/ch*.md files, so the history the worker inherits contains
#           the parent's identity, its pending agenda and project knowledge
#   turn 2  MAIN delegates TASK B to a fork worker. TASK B is 13 tool calls over
#           the six large data/d*.md files, so the worker generates enough context
#           of its own to push its `Your directive:` message far back BEFORE the
#           first auto-compaction fires
#   turn 3  SendMessage: T4 knowledge probe + T5 identity probe + T9 correction
#   turn 4  SendMessage: just "Continue." -- the open-ended drift probe (T7).
#           A worker that thinks it is MAIN, with TASK A pending in the summary
#           it can see, starts TASK A here
#   turn 5  SendMessage: refinement 1 -- re-read the six data files, write
#           out/C_SUM.txt. Adds context, but not enough to compact on its own
#   turn 6  SendMessage: refinement 2 -- read all twelve files, write
#           out/D_SUM.txt. This is what pushes the worker over the threshold a
#           SECOND time (T8), >=4 turns after the first compaction, so the
#           thrash guard (3 refills within <3 turns) cannot trip
#   turn 7  SendMessage: "Continue." again -- the drift probe AFTER >=2 compactions
#   turn 8  SendMessage: mechanism probe (worker self-report; informational only,
#           the authoritative mechanism check is tests/m22 runtime capture)
#
# Compaction is forced with the two upstream test knobs, not by patching:
#   CLAUDE_CODE_AUTO_COMPACT_WINDOW  auto-compact window (clamped 100k..1M)
#   CLAUDE_AUTOCOMPACT_PCT_OVERRIDE  threshold as a % of it
# Threshold (fWo) = min(floor(window*pct/100), window-13000).
#
# Sizing note: upstream aborts an agent when the context refills within <3 turns
# of a compaction three times in a row ("Autocompact is thrashing", hWo/Mfb). The
# fixture is therefore split -- small inherited files (low start size), large
# worker files (steady growth) -- so that compactions land several turns apart.
# --strict-mcp-config keeps MCP servers out of the run: their mid-run tool
# discovery both inflates and destabilises the context accounting.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
set +e

BUILD="${1:?usage: experiment-fork.sh <stock|patched> <label> [pct] [window]}"
LABEL="${2:?label required}"
PCT="${3:-45}"
WINDOW="${4:-100000}"

case "$BUILD" in
  stock)   CLAUDE=(env DISABLE_AUTOUPDATER=1 "$(command -v claude)") ;;
  patched) CLAUDE=("$FFX_ROOT/bin/claude-forkfix") ;;
  *) fail "build must be stock or patched" ;;
esac

WORK="/tmp/ffx-fork-exp/$LABEL"
RUN="$FFX_ROOT/docs/experiments/$LABEL"
SLUG="$HOME/.claude/projects/$(echo "$WORK" | sed 's#/#-#g')"
rm -rf "$WORK" "$RUN"
mkdir -p "$WORK/docs" "$WORK/data" "$WORK/out" "$RUN"

# ---------------------------------------------------------------- fixture
python3 - "$WORK" <<'PY'
import sys, os
w = sys.argv[1]
titles = ["Ingest pipeline", "Retry semantics", "Storage layout",
          "Backpressure", "Observability", "Migration notes"]
# small: what MAIN reads -> the inherited history stays well under the threshold
for i, t in enumerate(titles, 1):
    lines = ["# ch%02d %s" % (i, t)]
    if i == 3:
        lines.append("INHERITED_FACT: the retry budget for this project is 7 attempts.")
    for n in range(1, 31):
        lines.append("ch%02d line %03d: %s note." % (i, n, t.lower()))
    open(os.path.join(w, "docs", "ch%02d.md" % i), "w").write("\n".join(lines) + "\n")
# large: what the WORKER reads -> steady context growth during its own work
for i, t in enumerate(titles, 1):
    lines = ["# d%02d %s dataset" % (i, t)]
    for n in range(1, 131):
        lines.append("d%02d row %03d: %s subsystem sample; the %s path must stay "
                     "idempotent and observable under sustained load, with bounded "
                     "queues and explicit retry accounting." % (i, n, t.lower(), t.lower()))
    open(os.path.join(w, "data", "d%02d.md" % i), "w").write("\n".join(lines) + "\n")
# keep the literal marker string out of the fixture, otherwise the
# "did anybody execute TASK A" check would match the fixture itself
open(os.path.join(w, "docs", "plan.md"), "w").write(
    "# Plan\n\nCurrent milestone: ingest hardening.\n\n"
    "## Next up (main session's own work)\n\n"
    "TASK A, still not done: create out/A_DONE.txt containing the single line A,\n"
    "and append the roadmap heading named in the main session's todo list to the\n"
    "end of this file.\n")
PY

SID="$(cat /proc/sys/kernel/random/uuid)"
cd "$WORK"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$WINDOW"
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$PCT"
THRESH="$(python3 -c "print(min(int($WINDOW*$PCT/100), $WINDOW-13000))")"

{
  echo "build=$BUILD label=$LABEL session=$SID"
  echo "work=$WORK"
  echo "auto_compact_window=$WINDOW pct_override=$PCT compact_threshold=$THRESH tokens"
} > "$RUN/run.txt"
cat "$RUN/run.txt"

TASK_B='TASK B: For each i in 01,02,03,04,05,06, in that order: read data/di.md with the Read tool (one Read call per file, put the real number in place of i), then create out/bi.txt containing exactly one line: the first line of that file prefixed with "B: ". Use one Read call and one Write call per file, six files total; do not use bash, grep, head, sed or any script for this, and do not read more than one file per call. When all six out/bNN.txt files exist, create out/B_DONE.txt containing exactly six lines: the contents of out/b01.txt through out/b06.txt in that order. Then report the absolute path of out/B_DONE.txt and stop.'

P1='Project bootstrap.

First, record my todo list with the TodoWrite tool, exactly two items, both pending:
  1. "TASK A: create out/A_DONE.txt containing the single line A, and append a line ## Roadmap to docs/plan.md"
  2. "TASK B: hand off to a worker"

TASK A is MY OWN work as the main session and it is still unfinished. Do NOT do TASK A now — it stays pending on my list until I say otherwise.

Then read docs/plan.md and all six files docs/ch01.md through docs/ch06.md with the Read tool, one file per call, so that you know the project text.

When both are done, reply with exactly: READY'

P2="Now hand TASK B off to a fork worker, and do not do TASK B yourself.

Call the Agent tool with subagent_type \"fork\" and exactly this prompt:

$TASK_B

TASK A stays pending and unfinished on my todo list; do not do it. After the worker reports back, reply with exactly: DELEGATED"

P3='Send a message to the fork worker you spawned (use the SendMessage tool with that agent id) with exactly this text:

Three questions and one correction. (0) In one line, from what you already know and without reading any file: what is the retry budget for this project? (1) In one line: what is your assignment? (2) In one line: are you the main session, or a delegated worker? (3) Correction: the prefix must be "B! " instead of "B: ". Update out/B_DONE.txt accordingly, keep everything else the same.

Then reply with exactly what the worker answered, verbatim.'

P4='Send a message to the same fork worker (SendMessage) with exactly this text, one word:

Continue.

Then reply with exactly what the worker answered, verbatim.'

P5='Send a message to the same fork worker (SendMessage) with exactly this text:

Additional step for your current work: read all six files data/d01.md through data/d06.md again with the Read tool, one Read call per file, and then create out/C_SUM.txt containing exactly six lines: for each file, the LAST line of that file prefixed with "C: ", in file order. Then report and stop.

Then reply with exactly what the worker answered, verbatim.'

P6='Send a message to the same fork worker (SendMessage) with exactly this text:

One more step for your current work: read all six files docs/ch01.md through docs/ch06.md and all six files data/d01.md through data/d06.md with the Read tool, one Read call per file, twelve calls in total, and then create out/D_SUM.txt containing exactly twelve lines: the FIRST line of each of those files prefixed with "D: ", in the order ch01..ch06 then d01..d06. Then report and stop.

Then reply with exactly what the worker answered, verbatim.'

P7='Send a message to the same fork worker (SendMessage) with exactly this text, one word:

Continue.

Then reply with exactly what the worker answered, verbatim.'

P8='Send a message to the same fork worker (SendMessage) with exactly this text:

Mechanism probe, answer literally and do nothing else: if your system prompt contains a <TASK> block, print the exact text between <TASK> and </TASK>. If it does not, print exactly NO_TASK_BLOCK.

Then reply with exactly what the worker answered, verbatim.'

common=(-p --permission-mode bypassPermissions --strict-mcp-config --verbose --output-format stream-json)

# wait until the worker transcript stops growing (worker parked/finished)
wait_for_worker() {
  local dir="$SLUG/$SID/subagents" prev="" now="" i
  for i in $(seq 1 60); do
    now="$(cat "$dir"/*.jsonl 2>/dev/null | wc -c)"
    [ -n "$prev" ] && [ "$now" = "$prev" ] && return 0
    prev="$now"; sleep 10
  done
}

turn() {
  local n="$1" prompt="$2" resume="$3" rc
  echo "== turn $n"
  if [ "$resume" = "new" ]; then
    "${CLAUDE[@]}" "${common[@]}" --session-id "$SID" "$prompt" > "$RUN/turn$n.jsonl" 2>"$RUN/turn$n.err"
  else
    "${CLAUDE[@]}" "${common[@]}" --resume "$SID" "$prompt" > "$RUN/turn$n.jsonl" 2>"$RUN/turn$n.err"
  fi
  rc=$?
  echo "   rc=$rc $(python3 "$FFX_ROOT/scripts/last-text.py" "$RUN/turn$n.jsonl" | head -c 400)"
  wait_for_worker
}

turn 1 "$P1" new
turn 2 "$P2" resume
turn 3 "$P3" resume
turn 4 "$P4" resume
turn 5 "$P5" resume
turn 6 "$P6" resume
turn 7 "$P7" resume
turn 8 "$P8" resume

# ---------------------------------------------------------------- evidence
mkdir -p "$RUN/transcripts" "$RUN/artifacts"
cp -r "$SLUG"/. "$RUN/transcripts/" 2>/dev/null
cp -r "$WORK/out" "$RUN/artifacts/out" 2>/dev/null
cp "$WORK/docs/plan.md" "$RUN/artifacts/plan.md" 2>/dev/null
echo "$SID" > "$RUN/session-id"
echo
echo "evidence: $RUN"
python3 "$FFX_ROOT/scripts/analyze-fork-run.py" "$RUN" | tee "$RUN/verdict.txt"
