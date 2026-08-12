#!/usr/bin/env bash
# T-auto (no API, no model): unit-test the patch's own functions, lifted verbatim
# out of the built patched tree and executed with stubs for the six upstream
# symbols they use (yyt, cjt, rxe, lf, U0, fr).
#
# The important case is #3: the transcript of a fork that already compacted
# in-process. The reconstructed message list of such a fork no longer reaches the
# spawn entry, because the compact_boundary entry is written with
# parentUuid:null. The recovery must still return the ORIGINAL directive, byte
# for byte.
#
# Two fixtures are used for that case:
#   * synthetic - generated below, a redacted structural clone of the real
#     transcript (same entry shapes, same parentUuid:null boundary). It is what
#     makes this test runnable from a clean checkout.
#   * real - docs/experiments/patched-run1/…/subagents/agent-*.jsonl, the actual
#     evidence from the reference run. Raw *.jsonl streams are not published
#     (see .gitignore), so this fixture is used only when present locally and
#     reported as skipped otherwise.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

TREE="$FFX_ROOT/build/tree/$(m patch.target_basename)"
BUN="$FFX_ROOT/$(m runtime.bun_path)"
REAL=""
for f in "$FFX_ROOT"/docs/experiments/patched-run1/transcripts/*/subagents/agent-*.jsonl; do
  if [ -f "$f" ]; then REAL="$f"; break; fi
done
[ -f "$TREE" ] || fail "patched tree missing; run scripts/prepare-patched.sh"

H=/tmp/ffx-unit-$$.js
SYNTH=/tmp/ffx-unit-$$.synthetic.jsonl
CASES=/tmp/ffx-unit-$$.cases.json
trap 'rm -f "$H" "$SYNTH" "$CASES"' EXIT

# ---------------------------------------------------------------------------
# the synthetic compacted-fork transcript: entry shapes copied from the real
# one, all content replaced. Note what the post-boundary summary contains: a
# paraphrase that even repeats the "Your directive: " prefix, but no
# <fork-boilerplate> tag - exactly the shape that must NOT be accepted.
python3 - "$SYNTH" <<'PY'
import json, sys

DIRECTIVE = ('Measure the fork\'s post-compaction identity: run the "drift" probe,\n'
             'write out/D_SUM.txt, and report only what you measured — не пересказывай.')
BOILER = ("<fork-boilerplate>\nYou are a worker fork. The transcript above is the parent's "
          "history — inherited read-only context.\n</fork-boilerplate>\n\nYour directive: ")
AG, SID = "0000000000synth1", "00000000-0000-4000-8000-00000000cafe"


def u(n):
    return "00000000-0000-4000-8000-%012d" % n


def entry(n, typ, content, parent, **kw):
    e = {"parentUuid": parent, "isSidechain": True, "agentId": AG, "type": typ,
         "uuid": u(n), "timestamp": "2026-08-12T03:1%d:00.000Z" % (n % 10),
         "sessionId": SID, "version": "2.1.229", "cwd": "/tmp/ffx-synthetic",
         "userType": "external", "entrypoint": "sdk-cli", "gitBranch": "HEAD"}
    e["message"] = {"role": "assistant" if typ == "assistant" else "user",
                    "content": content}
    e.update(kw)
    return e


rows = [
    entry(1, "user", "parent chatter, inherited history", None),
    entry(2, "assistant", [{"type": "text", "text": "parent reply"}], u(1)),
    # the spawn entry: tool_result + the directive text block, as upstream writes it
    entry(3, "user", [{"type": "tool_result", "tool_use_id": "toolu_synthetic_1",
                       "content": [{"type": "text", "text": "Fork started"}]},
                      {"type": "text", "text": BOILER + DIRECTIVE}], u(2)),
    entry(4, "assistant", [{"type": "text", "text": "working on it"}], u(3)),
    entry(5, "user", [{"type": "text", "text": "more work"}], u(4)),
    # the boundary: parentUuid null is what breaks upstream's chain walk
    {"parentUuid": None, "logicalParentUuid": u(5), "isSidechain": True,
     "agentId": AG, "type": "system", "subtype": "compact_boundary",
     "content": "Conversation compacted", "isMeta": False,
     "timestamp": "2026-08-12T03:18:00.000Z", "uuid": u(6), "level": "info",
     "compactMetadata": {"trigger": "auto", "preTokens": 50329,
                         "preservedSegment": {"headUuid": u(5), "anchorUuid": u(5),
                                              "tailUuid": u(5)},
                         "postTokens": 10521}},
    # the summary: describes the PARENT's session and paraphrases the assignment
    entry(7, "user", [{"type": "text", "text":
                       "This session is being continued from a previous conversation.\n"
                       "Summary: the user is building claude-forkfix; the remaining work is "
                       "to push the repo. Your directive: continue the parent's push task."}],
          u(6)),
    entry(8, "assistant", [{"type": "text", "text": "post-compaction turn"}], u(7)),
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY

# each fixture's original directive, extracted independently (python, not the patch)
extract() {
  python3 - "$1" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    if '<fork-boilerplate>' not in line:
        continue
    e = json.loads(line)
    c = (e.get('message') or {}).get('content')
    t = c if isinstance(c, str) else "\n".join(
        b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
    if '<fork-boilerplate>' in t and 'Your directive: ' in t:
        sys.stdout.write(t.split('Your directive: ', 1)[1].strip())
        break
PY
}

# cases = [{label, path, expected}], one per available fixture
add_case() { # $1 = label, $2 = fixture path
  python3 - "$CASES" "$1" "$2" "$(extract "$2")" <<'PY'
import json, os, sys
path = sys.argv[1]
cases = json.load(open(path, encoding='utf-8')) if os.path.exists(path) else []
cases.append({"label": sys.argv[2], "path": sys.argv[3], "expected": sys.argv[4]})
json.dump(cases, open(path, 'w'))
PY
}

add_case synthetic "$SYNTH"
if [ -n "$REAL" ] && [ -f "$REAL" ]; then
  add_case "real (patched-run1)" "$REAL"
else
  echo "  note real transcript fixture not present (raw *.jsonl are local-only); synthetic clone only"
fi

# stubs + the patch block, lifted verbatim between its own markers
python3 - "$TREE" "$CASES" > "$H" <<'PY'
import json, sys
src = open(sys.argv[1], encoding='utf-8').read()
b, e = "// --- BEGIN fork-control patch", "// --- END fork-control patch"
i, j = src.index(b), src.index(e)
block = src[i:src.index("\n", j) + 1]
assert "ffxForkDirectiveFromTranscript" in block, "recovery helper not in the built tree"
cases = json.load(open(sys.argv[2], encoding='utf-8'))
assert cases and all(c["expected"] for c in cases), "a fixture yielded no directive"
print('const CASES=%s;' % json.dumps(cases))
print('''const yyt="fork-boilerplate", cjt="Your directive: ", rxe="fork";
function lf(a){return a}
let LT_PATH=null;
function U0(id){return LT_PATH}
function fr(){return require("fs")}
const BOILER="<fork-boilerplate>\\nYou are a worker fork. …\\n</fork-boilerplate>\\n\\n";
function msg(text){return {message:{content:text}}}
function msgBlocks(text){return {message:{content:[{type:"text",text:"noise"},{type:"text",text:text}]}}}
let rc=0;
function ok(name,cond,extra){console.log((cond?"  ok   ":"  FAIL")+" "+name+(extra?"  "+extra:""));if(!cond)rc=1}
''')
print(block)
print('''
// 1. spawn path, string content
ok("directive from spawn messages (string)",
   ffxForkDirectiveFromMessages([msg("parent chatter"),msg(BOILER+cjt+"DO X")])==="DO X");
// 2. spawn path, content blocks
ok("directive from spawn messages (blocks)",
   ffxForkDirectiveFromMessages([msgBlocks(BOILER+cjt+"DO Y")])==="DO Y");
// 3. THE regression: transcript of an already-compacted fork
for (const c of CASES) {
  LT_PATH=c.path;
  const got=ffxForkDirectiveFromTranscript("any-agent-id");
  ok("verbatim directive recovered from a compacted fork's transcript ["+c.label+"]",
     got===c.expected, "len="+(got?got.length:"undefined"));
  // 3b. the reconstructed post-compaction message list alone cannot do it
  const post=require("fs").readFileSync(c.path,"utf8").split("\\n").filter(Boolean)
    .map((l)=>{try{return JSON.parse(l)}catch(e){return null}}).filter(Boolean);
  const bIdx=post.findIndex((x)=>JSON.stringify(x).includes("<fork-boilerplate>"));
  const cIdx=post.findIndex((x)=>x.type==="system"&&x.compactMetadata);
  ok("fixture really is a compacted fork (boilerplate before the boundary) ["+c.label+"]",
     bIdx>=0&&cIdx>bIdx&&post[cIdx].parentUuid==null,
     "boilerplate #"+bIdx+", boundary #"+cIdx+" parentUuid="+JSON.stringify(post[cIdx]&&post[cIdx].parentUuid));
  ok("post-boundary slice alone yields nothing ["+c.label+"]",
     ffxForkDirectiveFromMessages(post.slice(cIdx))===undefined);
}
// 4. a summary that only paraphrases/quotes the directive is NOT accepted
ok("summarised restatement rejected (no boilerplate tag)",
   ffxForkDirectiveFromText("Summary: the fork's "+cjt+"do something else")===undefined);
// 5. non-fork agents get the identical value back
LT_PATH=null;
const parent=["PARENT PROMPT"];
ok("non-fork agentType: same array instance returned",
   ffxForkSystemPrompt(parent,{agentType:"general-purpose"},[msg(BOILER+cjt+"DO Z")],"id-nf")===parent);
// 6. fork: parent prompt preserved + fork-control appended with the verbatim TASK
const forked=ffxForkSystemPrompt(parent,{agentType:rxe},[msg(BOILER+cjt+"DO Z")],"id-f1");
ok("fork: parent prompt kept verbatim as element 0", forked[0]==="PARENT PROMPT"&&forked.length===2);
ok("fork: <fork-control> appended", forked[1].startsWith("<fork-control>"));
ok("fork: <TASK> holds the verbatim directive",
   forked[1].includes("<TASK>\\nDO Z\\n</TASK>"));
// 7. assignment is immutable per agentId
const again=ffxForkSystemPrompt(parent,{agentType:rxe},[msg(BOILER+cjt+"A DIFFERENT PARENT GOAL")],"id-f1");
ok("assignment immutable for the same agentId",
   again[1].includes("<TASK>\\nDO Z\\n</TASK>")&&!again[1].includes("A DIFFERENT PARENT GOAL"));
// 8. unrecoverable directive: fallback wording, no <TASK>, still a worker
const none=ffxForkSystemPrompt(parent,{agentType:rxe},[msg("no directive here")],"id-f2");
ok("no directive: fork-control still present, no <TASK> block",
   none[1].includes("<fork-control>")&&!none[1].includes("<TASK>"));
ok("no directive: told to report, not to substitute a parent goal",
   none[1].includes("Do not substitute a goal taken from the inherited parent history."));
process.exit(rc);
''')
PY

"$BUN" "$H"
