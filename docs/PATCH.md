# The patch: call/data flow, root cause, and what exactly changes

Everything below refers to Claude Code **2.1.229**, symbol names as they appear in
the bundle extracted from the stock binary
(`build/cli-extract-raw.js`, reproducible via `scripts/extract-bundle.py`).

## 1. How the installation is packaged

`~/.local/bin/claude` is a symlink to `~/.local/share/claude/versions/2.1.229`,
a **Bun single-file executable** (`bun build --compile --bytecode`, ELF x86-64,
311,175,440 bytes). The npm package `@anthropic-ai/claude-code@2.1.229` no longer
contains the JS — it is a thin installer that downloads this binary.

The binary is *not* opaque: the ELF section `.bun`
(section index 29, file offset `0x050c5000`) contains, next to the JSC bytecode,
the **complete JS bundle as plain UTF-8 text**:

| what | value |
|---|---|
| bundle offset in the file | 275,938,485 |
| bundle length | 25,407,636 bytes |
| first line | `// @bun @bytecode @bun-cjs` |
| shape | one CJS function wrapper: `(function(exports, require, module, __filename, __dirname) { … })` |

So a legitimate **text patch of a JS bundle** is possible. No hex editing, no
binary diff, no LD_PRELOAD, no memory patching — none of the forbidden
techniques are used, and the stock binary is only ever read.

The patched bundle is executed by a private, repo-local **bun 1.3.14**
(`runtime/package/bin/bun`, from `@oven/bun-linux-x64@1.3.14`). bun is required
because the bundle uses `using` (explicit resource management), which Node 22
cannot parse.

## 2. Fork subagent call/data flow

Fork module (bundle byte 5,272,967 ff.):

```js
yyt = "fork-boilerplate"; cjt = "Your directive: ";           // byte 505,601
function lvn(e){ return `<${yyt}>…You are a worker fork…</${yyt}>\n\n${cjt}${e}` }
function A4s(e,t){ /* buildForkedMessages */ }
Ere = { agentType:"fork" /* rxe */, tools:["*"], maxTurns:200, model:"inherit",
        permissionMode:"bubble", source:"built-in",
        getSystemPrompt:()=>"" }                               // byte 5,275,187
```

Note `getSystemPrompt:()=>""` — the fork agent definition has **no** system
prompt of its own. Every fork path therefore has to supply one explicitly, and
all of them supply *the parent's*:

| # | site | byte | what it passes |
|---|---|---|---|
| 1 | Agent tool, `subagent_type:"fork"` | 13,717,976 / 13,720,083 | `de = l.renderedSystemPrompt ?? lge({…})`, then `override:{systemPrompt:de, …}`, `forkContextMessages:l.messages`, `promptMessages:A4s(e,u)` (the `<fork-boilerplate> … Your directive: <TASK>` message) |
| 2 | `/fork` directive (`spawnForkFromDirective` = `fOn`) | 11,106,578 / 11,108,330 | `i = t.renderedSystemPrompt ?? await Vgv(t)`, `promptMessages:[…n, bn({content:[{type:"text",text:lvn(e)}]})]` |
| 3 | fork **resume / SendMessage** (`Vge`) | 14,110,160 / 14,111,970 | `ce` = "this agent is a fork"; `Re = s.renderedSystemPrompt ?? lge({…})` **rebuilt from the resumer's (main loop's) context**, then `override:{systemPrompt:Re}`, `forkContextMessages:void 0`, `promptMessages: j` (transcript) `+ the new message` |

All three funnel into the single subagent stream generator
**`$W`** (byte 11,057,148):

```js
async function*$W({agentDefinition:e, promptMessages:t, …, override:d, …, useExactTools:b, …}) {
  …
  ee = d?.agentId ? d.agentId : nO();                                // stable agent id
  …
  at = d?.systemPrompt ? d.systemPrompt : lf(await Cgv(e,r,ie,ft)),  // <-- THE hinge
  tr = XXp(at, b??!1, …),                                            // identity for forks
  sr = !b && … ? lf([...tr, appendSubagentSystemPrompt]) : tr        // identity for forks
  …
  for await (let Ir of Bhe({messages:J, systemPrompt:sr, …}))
```

For a fork, `sr === override.systemPrompt`, byte for byte.

`Bhe` → the query loop **`Xgp`** (byte 8,279,214):

```js
async function*Xgp(e,t){ let {systemPrompt:r, userContext:n, systemContext:o, …} = e
  while(!0){
    let Ve = yield*f.autocompact(_e, B, {systemPrompt:r, …}, …)      // byte 8,282,668
    if (Ve.kind==="compacted") { … _e = jst(Wr) }                    // messages only
    let it = lf(cyp(r,o))                                            // per-turn prompt
    … f.callModel({messages:…, systemPrompt:it, …})
  }
}
```

`r` is destructured **once** and never reassigned (verified: zero `r=`/`r+=` in
the whole function body). `jst(e)` =
`[boundaryMarker, …summaryMessages, …messagesToKeep, …attachments, …hookResults]`
— compaction replaces **the message list only**.

## 3. Why the fork loses its task at compaction

* The fork's identity ("you are a worker fork") and its assignment
  ("`Your directive: <TASK>`") live **only in a conversation message**
  (`lvn()` → `promptMessages`).
* The inherited parent history (`forkContextMessages`) is concatenated in front
  of it: `J = [...Oai(s), ...t]`. There is no protected prefix — `autocompact`
  receives the whole `_e`.
* When the threshold fires, the summariser rewrites everything into a summary of
  *the conversation*, which is overwhelmingly the **parent's** session: the
  parent's identity, its plans, its unfinished TODOs. The fork's own
  `<fork-boilerplate>`/directive message is one short message near the end of a
  long history and can be dropped or paraphrased away.
* The system prompt — the one thing compaction never touches — contains
  **nothing** about being a worker or about the assignment, because
  `FORK_AGENT.getSystemPrompt()` is `""` and the slot is used for the parent's
  prompt verbatim.

Result after a compact: system prompt says "you are the main Claude Code
session, here are your tools", history says "the user's project has these
unfinished tasks". Nothing anywhere says "you are a delegated worker and your
job is exactly B". The observed failure — a worker that finished its job, then
picked up the parent's next task from the summary — follows directly.

Pre-compaction mitigations (spawn hooks, notes files, prompt text) cannot fix
this, because they all live in the history that compaction rewrites.

## 4. What the patch changes

`patches/01-fork-control.patch` — **3 hunks, 2 removed lines, 127 added lines**,
one file (`cli.js`). Hunks 1 and 3 are the fork fix; hunk 2 is a build-integration
fix that the fork fix made necessary (§4.2).

### Hunk 1 — helper block, inserted after `lvn()` in the fork module

Top-level (same scope as `lvn`/`A4s`), no existing code touched:

* `ffxForkDirectiveFromText(e)` — given one text block, require the
  `<fork-boilerplate>` tag, then take everything after the last
  `"Your directive: "` → **the verbatim assignment string**. No model, no
  summarisation, no guessing.
* `ffxForkDirectiveFromMessages(e)` — scan `promptMessages` backwards for that
  block (handles both string and block-array message content).
* `ffxForkDirectiveFromTranscript(e)` — recovery path for a *cross-process*
  resume of a fork that has already compacted in-process, where the message
  scan cannot succeed (measured; see §7). Reads the agent's own transcript file via
  upstream's own `U0(agentId)` (`getAgentTranscriptPath`) — the very file
  upstream resumed the agent from — and takes the **first**
  `<fork-boilerplate>` entry, i.e. the original assignment. Read-only; no new
  files, no storage-schema change. Wrapped in `try/catch`: if anything fails it
  returns `undefined` and the fallback wording is rendered.
* `ffxRenderForkControl(e)` — renders the `<fork-control>` block: delegated
  worker identity, inherited history is background not agenda, `<TASK>…</TASK>`
  with the verbatim assignment, don't adopt the parent's unfinished
  goals/TODOs/plans, a compacted summary is not authoritative over this,
  later messages refine but never replace the assignment, report and stop.
* `ffxForkAssignments` — `Map<agentId, assignment>`; the assignment is
  registered **once** (at spawn) and is never overwritten, so one fork = one
  authoritative task for the whole life of the process (`SendMessage` and
  resume reuse the registered value).
* `ffxForkSystemPrompt(e,t,r,n)` — returns `e` unchanged unless
  `t.agentType === rxe` (`"fork"`); for a fork returns
  `lf([...e, renderForkControl(assignment)])`, i.e. the parent's prompt array
  plus one appended string. `lf` is the bundle's own SystemPrompt brand, and
  appending a string to that array is the existing idiom (see the
  `appendSubagentSystemPrompt` branch two lines below).

### Hunk 2 — the shell-snapshot exec path (§4.2: build integration, not the fork fix)

Found in real use, after the first behavioural runs: in a patched session the Bash
tool's `grep`, `find` and `pkill` printed **bun's help** instead of results.

Upstream's `getEnvironmentOverrides` puts `process.execPath` into
`CLAUDE_CODE_EXECPATH` for every Bash tool invocation (`TJs` is that name), and the
shell snapshot shadows those three commands with functions that re-exec that path
as a **multicall binary**:

```bash
local _cc_bin="${CLAUDE_CODE_EXECPATH:-}"
[[ -x $_cc_bin ]] || _cc_bin=/home/user/.local/bin/claude
if [[ ! -x $_cc_bin ]]; then command grep ${1+"$@"}; return; fi
( exec -a ugrep "$_cc_bin" -G --ignore-files --hidden -I --exclude-dir=.git … )
```

For the stock install `process.execPath` *is* the single-file launcher, which really
contains ugrep 7.5.0 and bfs. In this build the CLI is plain JS executed by the
private bun, so `process.execPath` is bun — and because bun is executable, the
shim's `[[ -x $_cc_bin ]]` fallback does **not** trigger: bun is handed ugrep's
flags and answers `error: Invalid Argument '-G'` plus its own help on stdout.
Reproduced in vivo with the variable unset (patched build, real Bash tool):

```
FFX_ENV=/home/user/claude-forkfix/runtime/package/bin/bun
error: Invalid Argument '-G'
Bun is a fast JavaScript runtime, package manager, bundler, and test runner. …
```

```diff
-if(c[TJs]=process.execPath,l)c.TMUX=l;
+if(c[TJs]=process.env.CLAUDE_CODE_EXECPATH||process.execPath,l)c.TMUX=l;
```

The bundle never *reads* `process.env[TJs]` anywhere (checked: this is the only
write and there is no read), so honouring a pre-set value changes nothing upstream
does — with the variable unset the expression is upstream's own. `scripts/run-patched.sh`
sets it to the **pinned stock binary**, which the shims then exec as
`ugrep`/`bfs` exactly as they do under stock. `tests/t12` proves it offline
(patch shape, launcher export, and the real shim replayed with both values);
`tests/m24` proves it end to end on both builds, comparing the raw tool output and
asserting both builds report the *same* exec path.

Why not the alternatives: unsetting the variable would work only by accident (the
shim's hardcoded fallback is `~/.local/bin/claude`, i.e. whatever the symlink
happens to point at, which is exactly what the fail-closed pinning exists to avoid),
and patching the snapshot generator would change stock's shell behaviour.

### Hunk 3 — one line in `$W`

```diff
-at=d?.systemPrompt?d.systemPrompt:lf(await Cgv(e,r,ie,ft)),
+at=d?.systemPrompt?ffxForkSystemPrompt(d.systemPrompt,e,t,ee):lf(await Cgv(e,r,ie,ft)),
```

This is the requested shape — `buildSystemPrompt(…)` → `if fork: append(renderForkControl(assignment))` —
placed at the single funnel through which **all** fork paths pass:

* spawn via the Agent tool, spawn via `/fork`, **and** resume/`SendMessage`
  (`Vge`), which a spawn-site-only patch would miss;
* the resulting array becomes `Xgp`'s `r`, so it is reused unchanged for every
  turn **after any number of compactions**;
* the `else` branch (no `override.systemPrompt`) is untouched, so ordinary
  subagents, named agents, reviewers and isolated agents keep
  `agentDefinition.getSystemPrompt(...)` exactly as before;
* non-fork agents that *do* pass `override.systemPrompt` (the plain Agent tool
  path, isolated agents) hit the `agentType !== "fork"` guard on the first line
  of the wrapper and get the identical value back.

### Invariant after the patch (hunks 1 and 3)

```
SYSTEM(fork) = SYSTEM(parent, verbatim array) + <fork-control> block
HISTORY(fork) = inherited parent history (compacted or not) + the fork's own work
```

Nothing is removed from the inherited history; the fix is additive and lives
outside the compactable region.

## 5. Why the patch needs a normalization step first

The three target lines in the minified bundle are 1,760, 4,165 and 22,312
characters long. A unified diff against them would be ~55 KB of unreadable noise,
which defeats the point of shipping a readable patch.

`scripts/normalize-bundle.py` therefore inserts newlines at **10 pinned anchor
strings** before patching (4 of them isolate hunk 2's 38-character target line and
its two context lines out of one 4,165-character line). This step is:

* exact-match (each anchor must occur **exactly once** — no fuzz, no search),
* provably inert (each anchor must be preceded by `,` `;` `{` or `}`, where a
  newline is neither a token boundary change nor an ASI hazard),
* whitespace-only (asserted: output-without-newlines == input-without-newlines,
  and exactly 10 newlines added),
* hash-pinned on both sides (`bundle.extracted_sha256`,
  `normalize.normalized_sha256`).

`tests/t06_normalize_whitespace_only.sh` re-proves all of that on every run.
The actual behaviour change is then a plain 140-line unified diff applied with
`patch --fuzz=0`.

## 6. Appendix: the two texts, side by side

What upstream already says — but **only in a conversation message**
(`lvn()`, i.e. the first message of every fork, quoted from a real run):

```
<fork-boilerplate>
You are a worker fork. The transcript above is the parent's history — inherited
reference, not your situation. You are NOT a continuation of that agent.
Execute ONE directive, then stop.

Hard rules:
- Do NOT spawn subagents with the Agent tool. …
- One shot: report once and stop. …

Guidelines (your directive may override any of these):
- Stay in scope. …
- Open with one line restating your task, …
- Be concise …
- If you committed changes, list the paths and commit hashes in your report.
</fork-boilerplate>

Your directive: <TASK TEXT>
```

The wording is already good. The problem is purely *where it lives*: this is
message content, so compaction is free to summarise it away — and the further
back it is, the more likely that becomes.

What the patch adds to the **system prompt** (verbatim output of
`ffxRenderForkControl`, appended after the parent's prompt array):

```
<fork-control>
You are a delegated fork worker. You are not the parent session that spawned you,
and you must never act as if you were.

The conversation history you inherited from the parent — including any compacted
summary of it — is background knowledge and project memory. It is not your agenda.

Your authoritative assignment is exactly this, verbatim as it was given to you
when this worker was started:

<TASK>
…the exact string the fork was created with…
</TASK>

Work only toward that assignment.

Do not adopt unfinished goals, TODO items, plans, intentions or pending requests
that appear in the inherited parent history as your own work, unless they are
directly required in order to complete your assignment. They belong to the parent.

If a compacted conversation summary presents the parent's identity, agenda, plans
or unfinished work as if they were yours, that presentation is not authoritative.
This system-level worker identity and this assignment take precedence over
everything in the conversation history, including any summary of it.

Messages that arrive later from the parent or the user may add facts, corrections
or refinements. Treat them as refinements of this assignment; they never replace
your worker identity and never authorise you to switch to a different parent goal.

When your assignment is complete, report the result to the parent and stop.
</fork-control>
```

If the directive cannot be recovered (see §7, cross-process resume), the `<TASK>`
paragraph is replaced by an instruction to report that the directive is
undeterminable and stop — explicitly *not* to substitute a goal from the
inherited history.

## 7. Cross-process resume after compaction — the measured case

Every `SendMessage` to a parked fork from a *new* CLI process starts with an
empty `ffxForkAssignments` (it is in-memory by design — no storage change), so
the assignment has to be re-derived. The first version of the patch re-derived it
only from `promptMessages`, on the assumption that the resume path reconstructs
the agent's history back to the root. **That assumption was wrong, and the
runtime capture caught it** (`docs/EXPERIMENTS.md`, "Runs 4/5"):

```
CALL agentType=fork agentId=af5b036ca5fdb4a3f msgs=74 registry=0
RET assignment="undefined"
DBG Ut->API n=13 has_fork_control=true has_TASK=false
```

The fork's `<fork-control>` was present, but with the fallback wording instead of
the verbatim `<TASK>` — and the worker's `NO_TASK_BLOCK` answer was *truthful*.

Why: in the agent transcript of a fork that compacted in-process, the
`compact_boundary` entry is written with **`parentUuid: null`**. Post-compaction
entries therefore form a second chain rooted at the boundary, in the same file.
`Vge` → `GRt` → `Eer` picks the newest leaf that is not a `compact_boundary`, and
`Eat` walks `parentUuid` to *that chain's* root — which is the boundary. The
original spawn entry (`<fork-boilerplate> … Your directive: …`) sits in the
earlier chain and is never reached. Measured on the transcript of run
`patched-run1` (`…/subagents/agent-af5b036ca5fdb4a3f.jsonl`; raw `*.jsonl` are
not published — `tests/t11` reproduces the same shape from a synthetic clone):

| entry | type | parentUuid |
|---|---|---|
| #2 | `user`, `<fork-boilerplate>` + directive | 63c45590 |
| #14 | `system`, `compactMetadata` | **null** |
| #15 | `user`, `isCompactSummary` | bca4cd4d |

Chain from the newest leaf: 40 entries, **boilerplate not included**.

The fix is `ffxForkDirectiveFromTranscript`: the entry is still on disk in the
file upstream itself just resumed from, so the verbatim directive is read back
from it (first match = the original). Re-measured on the *same* worker and the
same session after the fix:

```
n=13 chars=11359 fork_control=True TASK=True
task: 'TASK B: For each i in 01,02,03,04,05,06, in that order: read data/di.md …'
```

and byte-compared against the spawn entry: 629 chars, **exact match**. Covered by
`tests/t11_directive_recovery_unit.sh` (offline; a synthetic clone of that
transcript shape as the always-available fixture, the real transcript too when it
is present locally) and `tests/m22_fork_control_mechanism.sh` (runtime capture, differential).

## 8. Known residual gaps

* **Transcript unavailable.** If the agent transcript cannot be read and the
  in-memory mirror is used instead (`subagent_resume_transcript_missing`), or a
  future version renames/relocates it, `<fork-control>` renders its fallback
  wording: the worker identity and the "do not adopt the parent's agenda" rules
  still apply and the worker is told to report that it cannot determine its
  directive rather than invent one, but the verbatim `<TASK>` is not pinned.
  Closing that for good would mean persisting the assignment (e.g. in the agent
  `.meta.json` sidecar), i.e. a storage-schema change, which is out of scope by
  request.
* **Nested forks.** A fork spawning a fork re-derives the prompt from the
  *fork's* own context (`s6o` does not propagate `renderedSystemPrompt`), so the
  child's `<fork-control>` describes the child's directive — correct, but the
  child does not inherit the parent fork's block verbatim. Nested forks are out
  of scope.
* **`bAf` in-process teammate runner** (byte 13,677,145) re-enters `$W` without
  `override.systemPrompt`; it is not a fork path and is unaffected either way.
* **Hunk 2 depends on upstream's shim design, not just on one line.** The line
  itself is pinned (`patch --fuzz=0`, hash-checked), but the *reason* for it is the
  shell snapshot's multicall convention. If a future version stops embedding
  ugrep/bfs, or reads `CLAUDE_CODE_EXECPATH` somewhere else, the fix degrades to
  passing a variable nobody uses (inert) — while the failure it prevents (a shim
  exec'ing the private bun) would come back in any build that runs the bundle under
  a different interpreter. `tests/t12` asserts the premise itself, so it fails
  loudly if the shim stops behaving this way instead of silently passing.
