#!/usr/bin/env python3
"""Build a DIAGNOSTIC-ONLY instrumented copy of a cli.js bundle.

    scripts/make-debug-tree.py <in-cli.js> <out-cli.js>

This is *not* part of the shipped patch and is never used by bin/claude-forkfix.
Its only job is to make the verification objective: instead of asking the model
what its system prompt contains (which the model can get wrong in both
directions), the instrumented build records the exact system prompt array that
is handed to the API, and the test greps that recording.

What it inserts:
  * `ffxDbgDump(x)` -- identity function with a side effect: if the env var
    FFX_DEBUG_FILE is set, append one JSON line describing the system prompt
    array (length, whether <fork-control>/<TASK> are present, the verbatim
    <TASK> body, and the whole <fork-control> block).
  * a wrapper around every `systemPrompt:sr` site in $W -- i.e. exactly the
    value that becomes Xgp's `r` and is reused for every turn of the agent.

Both the patched tree and the unpatched normalized bundle accept the same
instrumentation, so the two recordings are directly comparable (tests/m22).
With FFX_DEBUG_FILE unset the instrumented build behaves like its input.
"""
import sys

SRC, DST = sys.argv[1], sys.argv[2]

HELPER = r"""function ffxDbgDump(x){try{let f=process.env.FFX_DEBUG_FILE;if(!f)return x;
let a=Array.isArray(x)?x:[x];let joined=a.map((s)=>typeof s==="string"?s:JSON.stringify(s)).join("\n\n");
let fc=null,tk=null;let i=joined.indexOf("<fork-control>");
if(i>=0){let j=joined.indexOf("</fork-control>",i);fc=joined.slice(i,j<0?joined.length:j+15)}
let p=joined.indexOf("<TASK>");if(p>=0){let q=joined.indexOf("</TASK>",p);if(q>=0)tk=joined.slice(p+6,q).trim()}
let nz=[];for(let ch of joined){let c=ch.codePointAt(0);if(c>127){nz.push(c);if(nz.length>=3)break}}
let sh=require("crypto").createHash("sha256").update(joined).digest("hex");
require("fs").appendFileSync(f,Buffer.from(JSON.stringify({n:a.length,total_chars:joined.length,
sha256:sh,has_fork_control:fc!==null,has_TASK:tk!==null,task:tk,fork_control:fc,nonascii:nz})+"\n","utf8"))}catch(e){}return x}
"""

ANCHOR = "function H4s(e,t){"          # pinned normalize anchor, start of a line
SITE = "systemPrompt:sr"

src = open(SRC, encoding="utf-8").read()
if ANCHOR not in src:
    sys.exit("anchor not found: %s" % ANCHOR)
n_site = src.count(SITE)
if n_site != 2:
    sys.exit("expected 2 %r sites, found %d" % (SITE, n_site))

out = src.replace(ANCHOR, HELPER + ANCHOR, 1)
out = out.replace(SITE, "systemPrompt:ffxDbgDump(sr)")
open(DST, "w", encoding="utf-8").write(out)
print("instrumented %s -> %s (%d capture sites)" % (SRC, DST, n_site))
