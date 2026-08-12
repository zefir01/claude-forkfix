#!/usr/bin/env python3
"""Read-only extraction of the JS bundle from the stock Claude Code binary.

The stock installation is a Bun single-file executable (`bun build --compile`).
The full JS bundle is embedded as plain text inside the ELF `.bun` section, so a
normal text patch is possible without touching the binary in any way.

This script only READS the stock binary. It never writes to it.

Everything is pinned in manifest.json:
  * the stock binary SHA-256
  * the byte offset + length of the embedded bundle
  * the SHA-256 of the extracted bundle

Any mismatch is a hard failure (Claude was updated / different build).
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def die(msg):
    print("INCOMPATIBLE WITH CURRENT CLAUDE VERSION", file=sys.stderr)
    print("reason: " + msg, file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    with open(os.path.join(ROOT, "manifest.json")) as f:
        m = json.load(f)

    binary = os.path.expanduser(m["upstream"]["binary"])
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "cli-extract-raw.js")

    if not os.path.isfile(binary):
        die("stock binary not found: %s" % binary)

    size = os.path.getsize(binary)
    if size != m["upstream"]["binary_size"]:
        die("stock binary size %d != expected %d" % (size, m["upstream"]["binary_size"]))

    got = sha256_file(binary)
    if got != m["upstream"]["binary_sha256"]:
        die("stock binary SHA-256 %s != expected %s" % (got, m["upstream"]["binary_sha256"]))

    off = m["bundle"]["offset"]
    length = m["bundle"]["length"]
    with open(binary, "rb") as f:
        f.seek(off)
        data = f.read(length)
    if len(data) != length:
        die("short read at offset %d" % off)

    got = hashlib.sha256(data).hexdigest()
    if got != m["bundle"]["extracted_sha256"]:
        die("extracted bundle SHA-256 %s != expected %s" % (got, m["bundle"]["extracted_sha256"]))

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(data)
    print("extracted %d bytes -> %s" % (length, out))


if __name__ == "__main__":
    main()
