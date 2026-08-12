# shellcheck shell=bash
# Shared helpers. Sourced by the other scripts, never executed directly.
set -euo pipefail

FFX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$FFX_ROOT/manifest.json"

incompatible() {
  echo "INCOMPATIBLE WITH CURRENT CLAUDE VERSION" >&2
  echo "reason: $*" >&2
  exit 1
}

fail() { echo "ERROR: $*" >&2; exit 1; }

# m <dotted.key> -> value from manifest.json
m() {
  python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d = d[int(k)] if k.isdigit() else d[k]
print(d)
PY
}

expand() { python3 -c 'import os,sys;print(os.path.expanduser(sys.argv[1]))' "$1"; }

sha() { sha256sum "$1" | cut -d' ' -f1; }

stock_binary() { expand "$(m upstream.binary)"; }
stock_symlink() { expand "$(m upstream.launcher_symlink)"; }

# The stock installation must still be the pinned version, otherwise the
# patched tree is stale and we refuse to run it.
require_pinned_stock_selected() {
  local link target want
  link="$(stock_symlink)"
  want="$(stock_binary)"
  [ -e "$link" ] || incompatible "stock launcher $link not found"
  target="$(readlink -f "$link")"
  [ "$target" = "$(readlink -f "$want")" ] || \
    incompatible "stock 'claude' now resolves to $target, but this patch is pinned to $want"
}
