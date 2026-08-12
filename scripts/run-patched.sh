#!/usr/bin/env bash
# Run the patched Claude Code. Thin, fail-closed launcher.
#
# Deliberately NOT set here: HOME, CLAUDE_CONFIG_DIR, XDG_*, ANTHROPIC_*,
# no --append-system-prompt, no extra settings file. The patched build reads
# exactly the same ~/.claude, the same settings, the same projects/sessions
# directory as stock `claude`.
#
# Exactly two env vars are set, neither of which touches model behaviour:
#
# DISABLE_AUTOUPDATER=1 is required by the "stock installation must stay
# untouched" rule: the auto-updater would otherwise download a new version into
# ~/.local/share/claude and repoint the stock launcher.
#
# CLAUDE_CODE_EXECPATH is what upstream puts in the Bash tool's environment so
# that the shell snapshot can re-exec the CLI as a multicall binary: grep, find
# and pkill are defined there as functions that run `exec -a ugrep "$_cc_bin"
# -G ...`. That only works for the stock single-file launcher, which really does
# contain ugrep; here the CLI is plain JS run by the private bun, so upstream's
# unconditional process.execPath would hand bun ugrep's flags and the shims would
# print bun's help instead of search results. The patch makes that assignment
# honour a pre-set value; we point it at the pinned stock binary, which is only
# ever executed as ugrep/fd/pkill by those shims. Sessions stay shared.
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET="$(m patch.target_basename)"
TREE="$FFX_ROOT/build/tree/$TARGET"
BUN="$FFX_ROOT/$(m runtime.bun_path)"

[ -f "$TREE" ] || fail "patched tree not built. Run: $FFX_ROOT/scripts/prepare-patched.sh"
[ -x "$BUN" ] || fail "private bun runtime missing: $BUN"

# Fail closed: refuse to run a stale build after a Claude update.
require_pinned_stock_selected
GOT="$(sha "$TREE")"
WANT="$(m patch.patched_sha256)"
[ "$GOT" = "$WANT" ] || incompatible "patched tree sha256 $GOT != expected $WANT (rebuild with scripts/prepare-patched.sh)"

exec env DISABLE_AUTOUPDATER=1 CLAUDE_CODE_EXECPATH="$(stock_binary)" \
  "$BUN" "$TREE" "$@"
