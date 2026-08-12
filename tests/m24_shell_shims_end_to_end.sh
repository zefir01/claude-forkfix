#!/usr/bin/env bash
# Regression, end to end: the Bash tool's grep/find shims must work on BOTH
# builds. The shims (installed by the shell snapshot) re-exec
# $CLAUDE_CODE_EXECPATH as a multicall binary; upstream sets that to
# process.execPath, which is the stock single-file launcher for stock and the
# private bun for this build. tests/t12 proves the mechanism offline; this test
# runs the real tool through a real session and reads the raw tool_result, not
# the model's paraphrase.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"
set +e

WORK="/tmp/ffx-m24"
rm -rf "$WORK"; mkdir -p "$WORK"
echo "ffx-needle in a file" > "$WORK/ffx-probe.txt"
STOCK="$(stock_binary)"
rc=0

CMD='echo "FFX_ENV=${CLAUDE_CODE_EXECPATH:-unset}"; grep -n ffx-needle ffx-probe.txt; find . -maxdepth 1 -name ffx-probe.txt'
PROMPT="Run exactly this one command with the Bash tool, without modifying it in any way, and then reply with just DONE:

$CMD"

run() { # $1 = stock|patched -> raw tool_result text on stdout
  local kind="$1" out="/tmp/ffx-m24-$1.jsonl"
  if [ "$kind" = stock ]; then
    ( cd "$WORK" && DISABLE_AUTOUPDATER=1 command claude -p --permission-mode bypassPermissions \
        --strict-mcp-config --verbose --output-format stream-json "$PROMPT" ) > "$out" 2>/dev/null
  else
    ( cd "$WORK" && "$FFX_ROOT/bin/claude-forkfix" -p --permission-mode bypassPermissions \
        --strict-mcp-config --verbose --output-format stream-json "$PROMPT" ) > "$out" 2>/dev/null
  fi
  python3 - "$out" <<'PY'
import json, sys
texts = []
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    msg = row.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        continue
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_result":
            c = b.get("content")
            if isinstance(c, str):
                texts.append(c)
            elif isinstance(c, list):
                texts += [x.get("text", "") for x in c if isinstance(x, dict)]
print("\n".join(texts))
PY
}

check() { # $1 = kind, $2 = raw tool_result text
  local kind="$1" out="$2" env_line
  env_line="$(printf '%s\n' "$out" | grep -o 'FFX_ENV=[^ ]*' | head -1)"
  echo "  $kind: ${env_line:-FFX_ENV=(not reported)}"
  printf '%s\n' "$out" | grep -q 'ffx-needle' \
    || { echo "  FAIL $kind: the grep shim returned no match"; rc=1; }
  printf '%s\n' "$out" | grep -q './ffx-probe.txt' \
    || { echo "  FAIL $kind: the find shim did not list ./ffx-probe.txt"; rc=1; }
  printf '%s\n' "$out" | grep -qi "Invalid Argument\|Usage: bun " \
    && { echo "  FAIL $kind: a shim ran the wrong multicall binary:"; printf '%s\n' "$out" | head -5; rc=1; }
  [ "$env_line" = "FFX_ENV=$STOCK" ] \
    || { echo "  FAIL $kind: CLAUDE_CODE_EXECPATH is not the pinned stock binary ($env_line)"; rc=1; }
}

check stock   "$(run stock)"
check patched "$(run patched)"

[ $rc = 0 ] && echo "  ok  grep/find shims work identically on stock and patched (same exec path)"
exit $rc
