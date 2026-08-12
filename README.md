# claude-forkfix

An experimental, self-contained patch for **Claude Code 2.1.229** that gives a
`subagent_type:"fork"` worker a *system-level* identity and assignment, so that
history compaction can no longer make it forget that it is a delegated worker or
make it adopt the parent session's unfinished agenda.

```
SYSTEM(fork)  = SYSTEM(parent session, verbatim)  +  <fork-control> block
HISTORY(fork) = inherited parent history (compacted or not) + the fork's own work
```

Nothing is removed from the inherited history. The fix is additive and lives in
the one place compaction never rewrites: the system prompt.

## The invariant

**This is not a fork of the Claude Code codebase.** The source of truth is

* the exact upstream version (pinned by SHA-256), plus
* one small, readable unified diff (`patches/01-fork-control.patch`, 140 lines,
  3 hunks, two existing lines changed), plus
* the regression tests.

`build/` is a disposable artifact, always reproducible from those three. The
installed stock `claude` is only ever **read**; it is never modified, replaced,
re-symlinked or shadowed.

## Layout

```
manifest.json                  every pinned fact: version, byte range, all SHA-256
patches/01-fork-control.patch  the change, as a git-compatible unified diff
scripts/extract-bundle.py      read-only slice of the JS bundle out of the stock binary
scripts/normalize-bundle.py    whitespace-only line splitting at 10 pinned anchors
scripts/prepare-patched.sh     build build/tree (fail-closed, hash-verified end to end)
scripts/check-compatibility.sh report-only: is this patch still valid for the install?
scripts/run-patched.sh         launcher used by bin/claude-forkfix
scripts/test-patch.sh          regression suite
scripts/experiment-fork.sh     the behavioural compaction experiment (T4-T9)
scripts/analyze-fork-run.py    verdict printer for one experiment run
scripts/make-debug-tree.py     DIAGNOSTIC ONLY: instrumented copy of a bundle that
                               records the system prompt handed to the API
bin/claude-forkfix             the patched command
runtime/                       private bun 1.3.14 that executes the patched bundle
upstream/                      npm tarball of the pinned version (reference only)
baseline/stock-files.tsv       size/mtime/sha256 of every installed stock file
tests/                         t*.sh automated, m*.sh model-level
docs/PATCH.md                  packaging, call/data flow, root cause, what changes
docs/EXPERIMENTS.md            how the compaction regression is reproduced and measured
docs/experiments/<label>/      evidence of each run (run log, verdict, artifacts)
```

Not in git (see `.gitignore`), because it is either a build artifact, a
third-party payload or a verbatim recording of a local session:

```
build/                    regenerate: ./scripts/prepare-patched.sh
runtime/                  npm pack @oven/bun-linux-x64@1.3.14 && tar xf *.tgz -C runtime
upstream/                 npm pack @anthropic-ai/claude-code@2.1.229
docs/experiments/**/*.jsonl    raw stream-json and transcript files of the runs
```

Both restores are hash-checked: `runtime.bun_sha256` in `manifest.json` is
verified on every build, and the stock binary's sha256 is verified before the
patch is applied — a different download fails closed instead of being used. The
raw `*.jsonl` streams are withheld on purpose: they are verbatim transcripts of
this machine's sessions (local paths, tool output, provider metadata). Everything
the docs cite *about* them — `run.txt`, `verdict.txt`, `turnN.err`, the produced
artifacts, the `agent-*.meta.json` headers — is committed, and
`scripts/experiment-fork.sh` + `scripts/analyze-fork-run.py` reproduce them from
scratch.

## Use it

```bash
./scripts/check-compatibility.sh     # changes nothing, prints versions + hashes + yes/no
./scripts/prepare-patched.sh         # builds build/tree/cli.js from stock + patch
./bin/claude-forkfix                 # <-- the patched Claude Code, same args as `claude`
./scripts/test-patch.sh              # automated regression tests
./scripts/test-patch.sh --with-model # + tests that make real API calls
```

`bin/claude-forkfix` takes exactly the arguments stock `claude` takes and returns
its exit code. It sets two variables: `DISABLE_AUTOUPDATER=1`, so that the patched
process cannot mutate the stock installation, and `CLAUDE_CODE_EXECPATH=<pinned
stock binary>`, which is the path the Bash tool's shell shims re-exec as
ugrep/bfs (see "What the patch does", hunk 2). It deliberately does **not** set
`HOME`, `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME` or `--append-system-prompt`.

On this machine the command is wired into `~/.bashrc` next to the existing
`claude` alias, mirroring its permission flag:

```bash
alias claude-forkfix='/home/user/claude-forkfix/bin/claude-forkfix --dangerously-skip-permissions'
```

`\claude-forkfix` (backslash) runs it without that flag. `claude` itself is
untouched and still resolves to the stock binary.

### Shared session storage

Stock `claude` and `claude-forkfix` are two executables over **one** storage:
the real `$HOME`, the real `~/.claude`, the same `projects/<slug>/` transcripts,
the same session ids, the same serialization format. A session started by either
build resumes under the other with `--resume <id>` — no export, no copy, no
migration (proven by `tests/m20`, `tests/m21`).

## What the patch does

Three hunks in the extracted bundle (`docs/PATCH.md` has the full story):

1. a helper block after the fork module's `lvn()`: extract the **verbatim**
   directive out of the `<fork-boilerplate> … Your directive: …` message (or, for a
   fork resumed by another process after it already compacted, out of the agent's
   own transcript file), remember it per `agentId`, and render the
   `<fork-control>` block;
2. one line in `getEnvironmentOverrides`, so that a pre-set `CLAUDE_CODE_EXECPATH`
   survives instead of being overwritten with `process.execPath`. Not part of the
   fork fix: the Bash tool's shell snapshot shadows `grep`/`find`/`pkill` with
   functions that re-exec that path as a multicall binary (`exec -a ugrep …`), which
   only works for the stock single-file launcher — under the private bun those three
   commands printed bun's help instead of results (found in real use; `tests/t12`,
   `tests/m24`);
3. one line inside the subagent stream generator `$W` — the single funnel through
   which spawn, `/fork` and resume/`SendMessage` all pass:

```diff
-at=d?.systemPrompt?d.systemPrompt:lf(await Cgv(e,r,ie,ft)),
+at=d?.systemPrompt?ffxForkSystemPrompt(d.systemPrompt,e,t,ee):lf(await Cgv(e,r,ie,ft)),
```

The wrapper returns its input unchanged unless the agent is a fork, so MAIN,
general-purpose subagents, named agents, reviewers, isolated agents, ordinary
compaction, tool transport, `SendMessage` and the UI are untouched.

The assignment is **immutable**: it is captured once, from the exact string the
fork was created with, and is never replaced by a later message or by a summary.

## Fail closed

Every stage is hash-pinned, and nothing is ever adapted, re-based or repaired
automatically:

| stage | guard |
|---|---|
| stock binary | size + SHA-256 from `manifest.json` |
| `claude` symlink | must still resolve to the pinned version |
| extracted bundle | SHA-256 |
| normalization | anchors unique, preceded by `,;{}`, whitespace-only, SHA-256 |
| patch | `patch -p1 --fuzz=0` (no fuzz, no offsets accepted) |
| patched bundle | SHA-256 |
| bun runtime | SHA-256 |

Any mismatch prints `INCOMPATIBLE WITH CURRENT CLAUDE VERSION` and exits
non-zero. There is no partial success and no fuzzy match
(`tests/t04`, `tests/t05` prove both).

## After Claude Code updates

The patched command keeps working off `build/tree` until you rebuild it; the
moment you touch it, it refuses loudly. The update procedure is deliberately
manual:

1. `./scripts/check-compatibility.sh` → reports the version/hash mismatch and
   `PATCH COMPATIBLE: no`.
2. `./scripts/prepare-patched.sh` → refuses with
   `INCOMPATIBLE WITH CURRENT CLAUDE VERSION`; it does not rebase anything.
3. Re-run the investigation on the new bundle: find `$W`, the fork agent
   definition (`getSystemPrompt:()=>""`), the `<fork-boilerplate>`/`Your directive: `
   constants, and the `at=d?.systemPrompt?…` hinge line.
4. Update `manifest.json` (version, binary size/sha, bundle offset/length/sha,
   anchors, normalized sha) and regenerate the patch against the new normalized
   bundle; update `patch.patched_sha256` and `patch.sha256`.
5. `./scripts/test-patch.sh` and then the model-level runs in
   `docs/EXPERIMENTS.md`.
6. Only after everything passes is the new version reachable through
   `claude-forkfix`.

No auto-rebase, no fuzz, no silent adaptation: an incompatibility is meant to be
visible.

## How the mechanism is verified

Not by asking the worker what its prompt contains — that answer proved unreliable
in both directions. `scripts/make-debug-tree.py` builds an instrumented copy of
*either* bundle (patched or unpatched) that appends the exact system prompt array
handed to the API to `$FFX_DEBUG_FILE`. The instrumentation is diagnostic-only, is
not part of `patches/`, is never used by `bin/claude-forkfix`, and is inert unless
that variable is set.

* `tests/t11_directive_recovery_unit.sh` — offline, no API: lifts the patch's own
  functions out of the built tree and runs them against **a transcript of a fork
  that already compacted**, asserting byte-exact recovery, immutability per
  `agentId`, and no-op behaviour for non-fork agents. It generates its own
  synthetic clone of that transcript shape (so a clean checkout can run it) and
  additionally uses the real one from `docs/experiments/patched-run1` whenever it
  is present locally — the raw `*.jsonl` are not published.
* `tests/m22_fork_control_mechanism.sh` — one fork spawned on each build; asserts
  `<fork-control>` + a byte-exact `<TASK>` in the captured prompt on patched, and
  neither on unpatched.
* `tests/m23_nonfork_subagent_unchanged.sh` — same capture for a
  `general-purpose` subagent in the *same* working directory on both builds: the
  two prompts must have the identical SHA-256 (T10).
* `tests/t12_shell_shim_execpath.sh` (offline) and
  `tests/m24_shell_shims_end_to_end.sh` (both builds, real Bash tool) — the
  `grep`/`find` shims must return real results, and both builds must report the
  same `CLAUDE_CODE_EXECPATH`.

## What the behavioural runs show

The reference pair is `docs/experiments/{stock-run6,patched-run3}` (scenario v5,
eight turns, one shared session each): **4 and 5 real auto-compactions inside the
worker**, both `OVERALL PASS`. The patched worker still knew its assignment after
five compactions and six cross-process resumes — the turn-8 probe printed the
whole `<TASK>` body, 697 characters, byte-identical to the spawn string.

Reported honestly: in four valid stock runs stock **never drifted** either. On
2.1.228 the summariser tends to quote the fork's directive verbatim into every
summary, which is a strong *de facto* mitigation for a tidy fixture like this one.
The patch's claim is therefore the structural one — the assignment lives in the
system prompt instead of depending on that tendency — and it is proven at byte
level (`tests/m22`, `tests/t11`), not by a behavioural difference. Details and the
full comparison table: `docs/EXPERIMENTS.md`, "Runs 8/9".

That pair was measured on **2.1.228**. After the upstream update to **2.1.229** the
patch was re-issued and the patched side was re-run (`docs/experiments/patched-run4`,
`OVERALL PASS`): **6** real compactions in the worker, both refinements applied,
TASK A untouched, and the turn-8 probe printed the whole `<TASK>` body again — 629
characters, byte-identical to the spawn string, with the directive surviving
verbatim in 6/6 summary hops. There is **no 2.1.229 stock control run**, so the
stock comparison above still stands on 2.1.228 alone
(`docs/EXPERIMENTS.md`, "Run 10").

## Known limits

See `docs/PATCH.md` §8: if the agent transcript cannot be read at all, the block
still pins the worker identity but not the verbatim `<TASK>`; nested forks and the
in-process teammate runner are out of scope.

---

# Итоговый отчёт

## 1. Установленная upstream-версия

**Claude Code 2.1.229** (`claude --version` → `2.1.229 (Claude Code)`). Патч жёстко
привязан именно к ней (`manifest.json: upstream.version_string`).

## 2. Где она физически находится

* `~/.local/bin/claude` — симлинк (mtime `1786569872`) →
  `~/.local/share/claude/versions/2.1.229`;
* сам файл — **Bun single-file executable** (ELF x86-64, `bun build --compile
  --bytecode`), 311 175 440 байт, sha256
  `200338139a3df04a9ad22233837d1fb53fb6dffa21cd82e47559bfaa115acc1b`;
* npm-пакет `@anthropic-ai/claude-code@2.1.229` — только инсталлятор, JS в нём нет;
* внутри ELF-секции `.bun` (file offset `0x050c5000`) лежит **полный JS-бандл
  обычным UTF-8 текстом**: offset 275 938 485, длина 25 407 636 байт, первая
  строка `// @bun @bytecode @bun-cjs`.

Поэтому патч — текстовый патч JS, а не бинарный. Ни hex-edit, ни binary diff, ни
LD_PRELOAD, ни memory-patch не использованы; stock-бинарь только читается.

## 3. Какая часть реализации fork найдена

Полный call/data flow с байтовыми смещениями — `docs/PATCH.md` §2:

* fork-модуль: `yyt="fork-boilerplate"`, `cjt="Your directive: "`, `lvn(e)`
  (строит сообщение-директиву), `A4s` (`buildForkedMessages`);
* определение агента `Ere`: `agentType:"fork"` (`rxe`), `tools:["*"]`,
  `maxTurns:200`, **`getSystemPrompt:()=>""`** — у fork нет своего system prompt;
* **три** пути создания/возобновления fork: Agent-tool (`subagent_type:"fork"`),
  `/fork` (`spawnForkFromDirective` = `fOn`), resume/`SendMessage` (`Vge`). Все три
  передают system prompt **родителя** и сходятся в одном генераторе `$W`;
* в `$W` — ключевая строка `at=d?.systemPrompt?d.systemPrompt:lf(await Cgv(...))`,
  затем `tr=XXp(at,...)`, `sr`;
* цикл запроса `Xgp` деструктурирует `systemPrompt:r` **один раз** и никогда не
  переприсваивает (проверено: ноль `r=`/`r+=` в теле), а `jst()` при compaction
  перестраивает **только список сообщений**;
* пороги compaction: `TGo` = `min(floor(window*pct/100), window-13000)`, тестовые
  ручки `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`;
  anti-thrash-guard `Llb`/`CGo` (3 переполнения за <3 хода → агент убивается);
* `U0(agentId)` = `getAgentTranscriptPath`, `fr()` = fs-обёртка — использованы
  патчем для восстановления директивы.

## 4. Почему task сейчас теряется при compaction

Identity («ты worker fork») и assignment («`Your directive: …`») существуют
**только как одно сообщение** в истории. Унаследованная история родителя приклеена
перед ними (`J=[...Oai(s), ...t]`), защищённого префикса нет — `autocompact`
получает всё. Summariser сжимает *разговор*, который на 90% является сессией
родителя: его identity, планы, незакрытые TODO. Короткое сообщение fork'а
где-то в середине длинной истории может быть перефразировано или выброшено.

А system prompt — единственное, что compaction не трогает — про worker'а и его
задачу **не содержит ничего**, потому что `getSystemPrompt()` пуст, а слот занят
промптом родителя. Итог: system говорит «ты главная сессия», история говорит «вот
незакрытые задачи проекта» — и наблюдавшийся баг (worker закончил своё, потом взял
задачу MAIN из summary) следует напрямую. Pre-compaction меры (spawn-hooks,
notes-файлы, текст в промпте) не помогают: они живут в той самой истории, которую
compaction перезаписывает.

## 5. Какие именно upstream-строки/функции меняет patch

Один файл (`cli.js`), **3 hunk'а** (1 и 3 — сам фикс fork'а, 2 — вынужденный
фикс интеграции сборки, см. ниже):

* **hunk 1** — вставка блока helper'ов сразу после `lvn()` в fork-модуле,
  существующий код не тронут: `ffxForkDirectiveFromText`,
  `ffxForkDirectiveFromMessages`, `ffxForkDirectiveFromTranscript`,
  `ffxRenderForkControl`, `ffxForkAssignments` (Map agentId→assignment, пишется
  один раз), `ffxForkSystemPrompt`;
* **hunk 2** — одна изменённая строка в `getEnvironmentOverrides` (`TJs` =
  `"CLAUDE_CODE_EXECPATH"`), к fork'у отношения не имеет:

```diff
-if(c[TJs]=process.execPath,l)c.TMUX=l;
+if(c[TJs]=process.env.CLAUDE_CODE_EXECPATH||process.execPath,l)c.TMUX=l;
```

  Найдено в эксплуатации: shell-snapshot подменяет `grep`, `find` и `pkill`
  функциями, которые ре-экзекают этот путь как multicall-бинарь
  (`exec -a ugrep "$_cc_bin" -G …`). У stock это тот самый single-file лончер, в
  котором действительно лежит ugrep 7.5.0 и bfs; здесь бандл исполняет приватный
  bun, и поскольку bun исполняем, фолбэк `[[ -x $_cc_bin ]]` не срабатывает — bun
  получает флаги ugrep и печатает `error: Invalid Argument '-G'` плюс свой хелп.
  Бандл нигде `process.env[TJs]` не **читает** (это единственная запись и ни одного
  чтения), поэтому уважение уже установленного значения ничего в поведении upstream
  не меняет: при пустой переменной выражение — исходное. `scripts/run-patched.sh`
  подставляет туда **пришпиленный stock-бинарь**, и шимы экзекают его как
  ugrep/bfs ровно так же, как под stock. Проверки: `tests/t12` (офлайн: форма
  патча, экспорт в лончере и реальный шим, проигранный с обоими значениями) и
  `tests/m24` (end-to-end на обоих билдах, сравнение сырого вывода инструмента);
* **hunk 3** — ровно одна изменённая строка в `$W`:

```diff
-at=d?.systemPrompt?d.systemPrompt:lf(await Cgv(e,r,ie,ft)),
+at=d?.systemPrompt?ffxForkSystemPrompt(d.systemPrompt,e,t,ee):lf(await Cgv(e,r,ie,ft)),
```

Это ровно запрошенная форма `buildSystemPrompt(...) → if fork:
append(renderForkControl(assignment))`, поставленная в единственную воронку, через
которую проходят **все** fork-пути, включая resume/`SendMessage`. Ветка `else` не
тронута → обычные subagents/named/reviewer/isolated агенты идут прежним путём;
non-fork агенты, которые передают `override.systemPrompt`, отсекаются первой
строкой обёртки (`t?.agentType!==rxe → return e`, тот же объект).

Инвариант после патча: `SYSTEM(fork) = SYSTEM(parent, массив дословно) +
<fork-control>`; `HISTORY(fork) = унаследованная история (сжатая или нет) +
собственная работа`. Из истории ничего не удаляется.

## 6. Размер patch

`patches/01-fork-control.patch` — **140 строк файла, 3 hunk'а, −2 / +127 строк**.

Читаемость обеспечена шагом нормализации: три целевые строки минифицированного
бандла имеют длину 1 760, 4 165 и 22 312 символов, поэтому
`scripts/normalize-bundle.py` вставляет переводы строки в **10 пришпиленных
анкеров** (каждый обязан встречаться ровно один раз, обязан быть предшествуем
`, ; { }`, изменение доказуемо whitespace-only и захэшировано с двух сторон —
`tests/t06`). Четыре из десяти анкеров нужны только для того, чтобы у hunk'а 2
целевая строка была 38 символов, а не 4 165.

## 7. Где находится unified diff

`patches/01-fork-control.patch`, sha256
`f6fcc511c24da406fad2fd84657267e4f7b4b5c1dbf87d1d36ec244e32a00540`. Его можно
открыть глазами: имена функций осмысленные, тексты `<fork-control>` — обычный
английский. Полный текст блока (дословный вывод `ffxRenderForkControl`)
продублирован в `docs/PATCH.md` §6 рядом с upstream-текстом `lvn()`.

## 8. Как собирается отдельная patched-версия

`./scripts/prepare-patched.sh`, 7 стадий, каждая с проверкой хэша:

1. проверка stock-бинаря (размер + sha256, симлинк, `--version`);
2. `extract-bundle.py` — чтение бандла из секции `.bun` →
   `build/cli-extract-raw.js`, sha `485b2cb7…`;
3. `normalize-bundle.py` → `build/cli-normalized.js`, sha `db6b426f…`;
4. `patch -p1 --fuzz=0`;
5. сверка результата с `patch.patched_sha256` =
   `60c126347c68ba33738cd77d697c4b4812df77ad4b233aada4ae9a36a5411eb3` и сборка
   `build/tree/` (cli.js + upstream-ресурсы);
6. проверка приватного runtime `runtime/package/bin/bun` **1.3.14** (sha
   пришпилен). bun нужен потому, что бандл использует `using` (explicit resource
   management), который Node 22 не парсит;
7. smoke-тест: `build/tree/cli.js --version` → `2.1.229 (Claude Code)`.

Patched-дерево — **артефакт сборки**; source of truth = upstream-версия + патч
(`tests/t02` воспроизводит patched cli.js с нуля и сверяет sha).

## 9. Доказательство, что stock installation не изменена

* `baseline/stock-files.tsv` — инвентарь: для каждого файла размер, mtime,
  sha256; для симлинка — цель и mtime. Две помеченные съёмки: **capture 1**
  (11 августа 2026, до начала работ: версии 2.1.225–2.1.228, `claude` → 2.1.228)
  и **capture 2** (12 августа 2026, после того как **сам upstream** обновился на
  2.1.229 и переставил симлинк). Строки удалённых upstream'ом версий не
  вычищаются, а остаются в инвентаре;
* `tests/t01_stock_untouched.sh` (PASS): каждый файл, который в install-root ещё
  есть, побайтово совпадает с baseline по size/mtime/sha256 — в том числе
  пришпиленный `2.1.229` (sha `200338139a…`); симлинк `~/.local/bin/claude`
  `-> …/versions/2.1.229`; в install-root **не добавилось ни одного файла**
  (сравнение множеств, не счётчик); `claude --version` = `2.1.229 (Claude Code)`,
  `command -v claude` = исходный путь;
* расхождения с baseline тест печатает как `note`, а не как FAIL, и вот почему:
  update на 2.1.229 сделал сам stock-инсталлятор при обычном старте `claude`
  (не мы), а старую версию `2.1.225` удалил его же
  `cleanupOldVersions` (`ujr`) с `VERSION_RETENTION_COUNT=2`: он сортирует версии
  по mtime и удаляет всё, кроме двух свежих незалоченных. Наши скрипты
  install-root только читают (ни одного записывающего вызова: `rm -rf` в
  репозитории адресован лишь `build/tree` и временным каталогам,
  `run-patched.sh` ставит `DISABLE_AUTOUPDATER=1`), так что повесить это на патч
  было бы неверно — как и скрыть;
* stock-бинарь только читается (`extract-bundle.py` открывает `rb`),
  `check-compatibility.sh` не меняет вообще ничего;
* пропатченное дерево живёт исключительно в `build/tree/` (`tests/t08` проверяет
  отсутствие пересечений).

Команда `claude` запускает ровно немодифицированный Claude Code; выбор «или stock,
или patched» нигде не навязывается.

## 10. Доказательство shared sessions stock ↔ patched

Никакого отдельного HOME, `~/.claude-forkfix`, `CLAUDE_CONFIG_DIR`, отдельной БД
проектов или каталога сессий нет (`tests/t07` проверяет окружение launcher'а на
отсутствие подмен). Сценарии:

* **m20**: stock создаёт сессию `b2713745-…` в `/tmp/ffx-session-test` и запоминает
  `MEMORY_MARKER_12345` → `claude-forkfix --resume` того же id **читает маркер**, и
  это **тот же файл транскрипта**, который вырос 12 972 → 15 188 байт;
* **m21**: patched создаёт сессию `08128396-…`, запоминает `MEMORY_MARKER_67890` →
  stock `claude --resume` читает маркер;
* общий список: обе сессии (созданная stock и созданная patched) лежат в одном
  каталоге `~/.claude/projects/-tmp-ffx-session-test` и обе видны обоим бинарям.

Формат сериализации сессий не менялся, схема persistent-хранилища не менялась.

## 11. Результаты T4–T10

Автоматика: **17/17 PASS** (`t01`–`t12`, `m20`–`m24`) на финальной сборке.

| тест | результат | чем доказано |
|---|---|---|
| T4 fork наследует историю MAIN | PASS | worker без чтения файлов ответил «7 attempts — из `INHERITED_FACT` в `docs/ch03.md`, унаследованный контекст» (оба билда); транскрипт начинается с `fork-context-ref` |
| T5 отдельная identity | PASS | «A delegated fork worker (subagent `a03580fde72c5e611`), not the main session» |
| T6 реальный compaction, затем продолжение B | PASS | 4 (stock) и 5 (patched) настоящих auto-compaction внутри worker'а, TASK B доведён до конца |
| T7 regression | PASS на patched, см. §12 | `out/A_DONE.txt` отсутствует, `docs/plan.md` не изменён, ни одного мутирующего вызова по TASK A |
| T8 ≥2 цикла compaction | PASS | 4 и 5 compaction'ов в одном worker'е, thrash-guard не сработал |
| T9 `SendMessage` уточняет, но не подменяет | PASS | коррекция `B! ` применена; refinement 1 (`C_SUM.txt`, 6 строк) и refinement 2 (`D_SUM.txt`, 12 строк) выполнены; при этом на 8-м ходу worker напечатал **исходную** директиву — уточнения её не заменили |
| T10 non-fork subagent не изменён | PASS | `tests/m23`: захваченный в рантайме system prompt `general-purpose` субагента **побайтово идентичен** на обоих билдах — sha256 `95d5690f4259a2c4…`, 3 014 символов, 4 части; `<fork-control>`/`<TASK>` нет ни там, ни там |
| T2/T3/T11 | PASS | m20/m21; t04/t05 |

Числа в таблице — из эталонной пары на 2.1.228; повторный поведенческий прогон на
2.1.229 (только patched) — §12a.

Отдельно — **механизм**, и он проверяется не самоотчётом модели (тот однажды уже
ввёл в заблуждение в обе стороны), а рантайм-захватом: `make-debug-tree.py` строит
диагностическую копию **любого** бандла, которая дописывает точный массив system
prompt, ушедший в API.

* `tests/m22`: на stock — 0 блоков `<fork-control>`, 0 `<TASK>`; на patched —
  `<fork-control>` присутствует и `<TASK>` **побайтово равен** строке спавна (133
  символа), промпт родителя на месте (блок только добавлен), текст корректный
  UTF-8 в рантайме (U+2014);
* `tests/t11`: офлайн, без API — берёт функции патча из собранного дерева и
  проверяет их на **транскрипте уже сжатого fork'а**: дословное восстановление,
  иммутабельность по `agentId`, no-op для non-fork, отказ принимать пересказ
  вместо оригинала. Транскрипт берётся из двух источников: синтетический клон,
  который тест генерирует сам (13 assertion'ов, работает в чистом клоне), плюс
  реальный транскрипт из `docs/experiments/patched-run1`, если он есть локально
  (16 assertion'ов; сырые `*.jsonl` в репозиторий не выкладываются).

Отдельная регрессия, найденная в эксплуатации (шимы `grep`/`find`/`pkill`
печатали хелп bun вместо результатов, §5 hunk 2), закрыта двумя тестами:
`tests/t12` (офлайн: форма патча + реальный шим, проигранный со stock-бинарём и с
bun — со stock он находит строку, с bun отвечает `Invalid Argument '-G'`) и
`tests/m24` (end-to-end на обоих билдах: сырой tool_result содержит совпадение
`grep` и путь от `find`, а `CLAUDE_CODE_EXECPATH` у обоих билдов один и тот же —
`…/versions/2.1.229`).

## 12. Stock vs patched на regression T7 — честно

Эталонная пара — `docs/experiments/stock-run6` и `docs/experiments/patched-run3`
(сценарий v5, 8 ходов, одна общая сессия, порог 45 000 токенов). Обе —
`OVERALL PASS`.

| | stock-run6 | patched-run3 |
|---|---|---|
| настоящих compaction'ов в worker'е | 4 | 5 |
| thrash-guard | не сработал | не сработал |
| pre→post | 41 674→11 463 · 36 026→4 075 · 39 468→16 737 · 42 274→6 157 | 41 655→11 288 · 36 254→4 407 · 34 971→10 491 · 35 950→6 303 · 36 195→5 967 |
| TASK A на диске | нет, `plan.md` не изменён | нет, `plan.md` не изменён |
| `Continue.` после 4–5 сжатий | «Nothing remains on my brief … TASK A … that's the main session's own work, not mine» | «Nothing outstanding … TASK A stays pending and unfinished» |
| проба механизма (ход 8) | `NO_TASK_BLOCK` | **печатает весь `<TASK>`** |

Последняя строка — главное. В `patched-run1` эта же проба ответила
`NO_TASK_BLOCK`, и рантайм-захват показал, что ответ был **правдой**: сработала
fallback-формулировка. Причина оказалась не в модели: у записи `compact_boundary`
в транскрипте агента `parentUuid: null`, поэтому цепочка `Vge`→`GRt`→`Eer`→`Eat`
укореняется в границе сжатия и до записи спавна не доходит (таблица измерений —
`docs/PATCH.md` §7). Исправление — `ffxForkDirectiveFromTranscript`: читать
директиву из того же файла транскрипта, из которого upstream только что и
возобновил агента, через его же `U0(agentId)`; только чтение, никаких новых файлов
и никаких изменений схемы. Теперь, после **пяти** сжатий и шести межпроцессных
resume, worker напечатал своё задание, и оно совпало со строкой спавна побайтово:
`spawn 697 / printed 697 / byte-identical: True`.

**И stock тоже прошёл — сообщаю как измерено, а не как хотелось.** В четырёх
валидных stock-прогонах (4, 1, 1 и 4 сжатия) stock **ни разу не сдрейфовал**.
Видно и почему: в каждом hop'е обоих прогонов summariser воспроизводил директиву
дословно и помечал identity worker'а («hop 1…4: verbatim directive in summary: yes
| worker identity in summary: yes»). То есть на 2.1.228 summariser — сильная
*де-факто* защита для такой аккуратной подставки, и баг, ради которого всё
делалось (наблюдался в реальности, на куда более большой и грязной истории),
**воспроизвести по требованию здесь не удалось**. Что пара всё-таки устанавливает:

* патч ничего не ломает из того, что делает stock — те же артефакты, те же
  уточнения, те же ответы про identity, плюс один лишний переживший compaction;
* assignment больше **не зависит** от доброй воли summariser'а: на stock это текст,
  который summary случайно цитирует, на patched — это system prompt вне сжимаемой
  области, побайтово равный строке спавна. Именно это измеряют `m22`, `t11` и проба
  на 8-м ходу.

Итог по матрице без прикрас: T4–T6, T8, T9 продемонстрированы на обоих билдах; T7
продемонстрирован как «patched не дрейфует» при stock в роли не-воспроизводящего
контроля; сам механизм, делающий дрейф структурно невозможным, доказан на уровне
байтов, а не поведения.

### 12a. Перепроверка на 2.1.229 (`patched-run4`)

Вся пара выше измерена на **2.1.228**. После upstream-обновления до **2.1.229**
(§9) патч перевыпущен, и поведенческий прогон повторён:
`docs/experiments/patched-run4`, тот же сценарий v5, порог 45 000, 8 ходов,
`OVERALL PASS`. **Перезапускался только patched — stock-контроля на 2.1.229 нет**,
поэтому про stock эта строка ничего нового не говорит; сравнение stock/patched
остаётся тем, что выше, на 2.1.228.

| | patched-run3 (2.1.228) | patched-run4 (2.1.229) |
|---|---|---|
| настоящих compaction'ов в worker'е | 5 | **6** |
| thrash-guard | не сработал | не сработал |
| pre→post | 41 655→11 288 · 36 254→4 407 · 34 971→10 491 · 35 950→6 303 · 36 195→5 967 | 36 962→12 124 · 36 303→6 588 · 39 136→11 699 · 38 794→8 892 · 36 652→7 757 · 37 326→9 791 |
| TASK A на диске (T7) | нет, `plan.md` не изменён | нет, `plan.md` не изменён |
| refinement'ы (T9) | `C_SUM` 6, `D_SUM` 12 | `C_SUM` 6, `D_SUM` 12 |
| identity (T5) | «A delegated fork worker (subagent …), not the main session» | «A delegated fork worker, not the main session» |
| `Continue.` (T7) | «Nothing outstanding …» | ход 4: «TASK B is done; there's nothing left in my brief to continue»; ход 7: перепроверил 12 чтений и отчитался по `D_SUM` |
| проба механизма (ход 8) | печатает весь `<TASK>` | **печатает весь `<TASK>`** |
| выживание assignment'а в summary | 5/5 hop'ов дословно | **6/6 hop'ов дословно, identity помечена во всех 6** |

Побайтовое сравнение — после **шести** сжатий и семи межпроцессных resume:
`spawn 629 / printed 629 / byte-identical: True`. 629 против 697 в run3 — не
обрезка: промпт форка формулирует сам MAIN на 2-м ходу, и в run3 он дописал от себя
фразу про «TASK A stays pending», а в run4 не дописал; в `<TASK>` лежит ровно то,
что MAIN отправил. Механизм перенёсся без изменений, хотя обновление переименовало
все затронутые символы (§14).

## 13. Как patcher обнаруживает update/incompatibility

Fail closed на каждой стадии (таблица — «Fail closed» выше), ничего не
«подгоняется». Любое расхождение → `INCOMPATIBLE WITH CURRENT CLAUDE VERSION` и
ненулевой exit code, без частичного успеха и без попыток «починить» патч.
`tests/t04` (мутирована целевая строка; мутирован context-line — и отдельно
подтверждено, что fuzzy-apply прошёл бы) и `tests/t05` (несовпадение версии;
несовпадение sha бинаря) это доказывают.

Диагностика, которая ничего не меняет: `./scripts/check-compatibility.sh` —
печатает версии, все хэши (ожидаемые и фактические), применимость патча, состояние
patched-дерева и итог `PATCH COMPATIBLE: yes|no`. Сейчас: `yes`.

## 14. Какие риски остаются

* **Транскрипт недоступен.** Если файл транскрипта агента прочитать нельзя
  (upstream-путь `subagent_resume_transcript_missing`, используется in-memory
  зеркало) или будущая версия его переименует, `<fork-control>` отрендерится с
  fallback-формулировкой: identity worker'а и запрет присваивать agenda родителя
  останутся, worker'у велено **сообщить**, что директиву определить нельзя, а не
  выдумывать её, — но дословный `<TASK>` не будет пришпилен. Закрыть окончательно =
  персистить assignment (например, в `.meta.json` агента), т.е. менять схему
  хранения, что вне рамок задачи.
* **Вложенные fork'и.** Fork, спавнящий fork, пересобирает промпт из контекста
  *самого fork'а* (`s6o` не пробрасывает `renderedSystemPrompt`), поэтому у ребёнка
  `<fork-control>` описывает его собственную директиву — корректно, но блок
  родителя-fork'а дословно не наследуется. Вне рамок.
* **Привязка к одной сборке.** Патч пришпилен к 2.1.229; любой апдейт требует
  ручного повтора исследования (§13, §16). Уязвимые к переименованию точки:
  `$W`-строка, `rxe`/`yyt`/`cjt`, `lf`, `U0`, `fr`, `TJs`, 10 анкеров нормализации.
  Насколько это реально: переход 2.1.228 → 2.1.229 переименовал **все** эти
  символы (`Uht→yyt`, `wUt→cjt`, `ake→rxe`, `of→lf`, `LT→U0`, `hQs→TJs`,
  `Z5→$W`, `Hcp→Xgp`), сохранив структуру, — патч упал закрыто, исследование и
  перегенерация патча заняли один проход по §16.
* **Shell-шимы зависят не только от одной строки.** Сама строка пришпилена
  (`--fuzz=0` + хэши), но смысл hunk'а 2 — в конвенции multicall у shell-snapshot.
  Если upstream перестанет встраивать ugrep/bfs или начнёт читать
  `CLAUDE_CODE_EXECPATH` где-то ещё, фикс выродится в передачу никем не читаемой
  переменной (безвредно), тогда как сама поломка вернётся в любой сборке, которая
  исполняет бандл другим интерпретатором. `tests/t12` проверяет саму предпосылку,
  поэтому упадёт громко, а не пройдёт молча.
* **Стоимость контекста.** Блок `<fork-control>` — 1 491 символ при 133-символьной
  задаче (≈1 358 символов постоянного текста + сама директива), т.е. порядка
  350–400 токенов на каждый ход fork'а; для длинной директивы блок растёт
  пропорционально.
* **Регрессия «не измерена как разница поведения»** — см. §12.
* **Приватный bun.** Patched-сборку исполняет свой bun 1.3.14, а не тот
  интерпретатор, что встроен в stock-бинарь (там JSC-байткод внутри single-file
  executable). Версия bun совпадает с той, которой собран upstream-бинарь, но это
  всё же не тот же самый процесс исполнения.
* **Диагностическая инструментация** (`make-debug-tree.py`) пишет system prompt в
  файл в открытом виде — нужна только тестам, никогда не участвует в
  `bin/claude-forkfix`, бездействует без `FFX_DEBUG_FILE`.

## 15. Точная команда запуска patched Claude

```bash
/home/user/claude-forkfix/bin/claude-forkfix                      # интерактивно
/home/user/claude-forkfix/bin/claude-forkfix --resume <session-id>
```

Плюс алиас в `~/.bashrc` (см. «Use it»):

```bash
alias claude-forkfix='/home/user/claude-forkfix/bin/claude-forkfix --dangerously-skip-permissions'
```

Аргументы передаются без изменений, exit code возвращается как есть. Тот же
`~/.claude`, те же сессии, тот же UI/messaging. Команда `claude` остаётся ровно
stock. Лончер ставит две переменные и ни одной больше: `DISABLE_AUTOUPDATER=1`
(чтобы patched-процесс не мог мутировать stock-инсталляцию) и
`CLAUDE_CODE_EXECPATH=<пришпиленный stock-бинарь>` (путь, который shell-шимы Bash
экзекают как ugrep/bfs, §5 hunk 2). Ни `HOME`, ни `CLAUDE_CONFIG_DIR`, ни `XDG_*`,
ни `--append-system-prompt`, ни отдельного settings-файла — `tests/t07`.

## 16. Точная процедура обновления patch после следующего релиза Claude

1. `./scripts/check-compatibility.sh` → покажет расхождение версии/хэшей и
   `PATCH COMPATIBLE: no` (ничего не меняет).
2. `./scripts/prepare-patched.sh` → откажется с `INCOMPATIBLE WITH CURRENT CLAUDE
   VERSION`, ничего не ребейзит. До момента, когда вы сами пересоберёте,
   `claude-forkfix` продолжает работать со старого `build/tree`.
3. Повторить исследование на новом бандле: найти `$W` и строку
   `at=d?.systemPrompt?…`, определение fork-агента (`getSystemPrompt:()=>""`),
   константы `fork-boilerplate`/`Your directive: `, а также `U0`/`fr`/`lf`, запись
   `c[TJs]=process.execPath` (hunk 2) и 10 анкеров нормализации.
4. Обновить `manifest.json` (версия, размер/sha бинаря, offset/length/sha бандла,
   анкеры, normalized sha) и перегенерировать патч против нового нормализованного
   бандла; обновить `patch.patched_sha256` и `patch.sha256`.
5. `./scripts/test-patch.sh` (17 тестов), затем model-уровневые прогоны по
   `docs/EXPERIMENTS.md`: `./scripts/experiment-fork.sh patched <label>` и
   `stock <label>`, и `scripts/analyze-fork-run.py` для вердикта.
6. Только после того, как всё зелёное, новая версия становится доступна через
   `claude-forkfix`.

Никакого авто-ребейза, fuzz'а и молчаливой адаптации: несовместимость должна быть
заметной. Инвариант соблюдён — репозиторий остаётся «upstream + 140-строчный diff +
тесты», а не форком кодовой базы Claude Code.
