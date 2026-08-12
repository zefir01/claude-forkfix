#!/usr/bin/env bash
# T-auto: the patched build starts, reports the same version, and the patched
# bundle still parses/loads (bun --version + a --help round trip).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"

rc=0
ver="$("$FFX_ROOT/bin/claude-forkfix" --version 2>&1 | head -1 | tr -d '\r')"
[ "$ver" = "$(m upstream.version_string)" ] || { echo "  FAIL patched --version = '$ver'"; rc=1; }
echo "  claude-forkfix --version -> $ver"

out="$("$FFX_ROOT/bin/claude-forkfix" --help 2>&1)"
echo "$out" | grep -q -- '--resume' || { echo "  FAIL --help output looks wrong"; rc=1; }
echo "  claude-forkfix --help works ($(echo "$out" | wc -l) lines)"

exit $rc
