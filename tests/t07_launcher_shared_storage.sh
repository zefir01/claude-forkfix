#!/usr/bin/env bash
# T-auto: the launcher must not redirect config/session storage and must not
# inject any prompt/settings beyond the patch itself.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

rc=0
L="$FFX_ROOT/scripts/run-patched.sh $FFX_ROOT/bin/claude-forkfix $FFX_ROOT/scripts/lib.sh"

# no storage redirection anywhere in the launch path. CLAUDE_CODE_EXECPATH is the
# one CLAUDE_CODE_* name allowed (see tests/t12): it is not storage or prompt
# state, it is the path the Bash tool's shell shims re-exec as ugrep/bfs, and it
# must be the stock binary because the patched build runs under bun.
for bad in 'HOME=' 'CLAUDE_CONFIG_DIR' 'XDG_CONFIG_HOME' 'XDG_DATA_HOME' \
           'append-system-prompt' 'system-prompt' 'settings' 'ANTHROPIC_'; do
  # shellcheck disable=SC2086
  if grep -n "$bad" $L | grep -v '^\S*:[0-9]*:#' | grep -q .; then
    echo "  FAIL launcher mentions '$bad' outside comments:"; grep -n "$bad" $L | grep -v '^\S*:[0-9]*:#'
    rc=1
  fi
done
# shellcheck disable=SC2086
if grep -n 'CLAUDE_CODE_' $L | grep -v '^\S*:[0-9]*:#' | grep -v 'CLAUDE_CODE_EXECPATH="\$(stock_binary)"' | grep -q .; then
  echo "  FAIL launcher sets a CLAUDE_CODE_* var other than EXECPATH:"
  grep -n 'CLAUDE_CODE_' $L | grep -v '^\S*:[0-9]*:#' | grep -v 'CLAUDE_CODE_EXECPATH="\$(stock_binary)"'
  rc=1
fi

# exactly two env vars are set: the updater kill switch and the shim exec path
execline="$(awk '/^exec env/{f=1} f{printf "%s ", $0} f&&!/\\$/{exit}' \
            "$FFX_ROOT/scripts/run-patched.sh")"
envs="$(printf '%s' "$execline" | grep -o '[A-Z_][A-Z_]*=' | tr -d '=' | tr '\n' ' ')"
[ "$envs" = "DISABLE_AUTOUPDATER CLAUDE_CODE_EXECPATH " ] \
  || { echo "  FAIL unexpected env in exec line: '$envs'"; rc=1; }

# the patched command is not installed as `claude`
[ -e "$FFX_ROOT/bin/claude" ] && { echo "  FAIL bin/claude exists"; rc=1; }
[ "$(command -v claude)" = "$(stock_symlink)" ] || { echo "  FAIL 'claude' no longer resolves to the stock symlink"; rc=1; }

# no separate config dir was created
for d in "$HOME/.claude-forkfix" "$HOME/.config/claude-forkfix" "$FFX_ROOT/home"; do
  [ -e "$d" ] && { echo "  FAIL separate config dir exists: $d"; rc=1; }
done

echo "  launcher passes args through; env vars: DISABLE_AUTOUPDATER, CLAUDE_CODE_EXECPATH=<stock binary>"
echo "  (session sharing itself is verified by tests/m20_* and tests/m21_*)"

exit $rc
