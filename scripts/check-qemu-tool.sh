#!/usr/bin/env bash
set -euo pipefail

# Guest images are built and booted through the qemu-tool CLI, never through
# the standalone gen-vm / run-vm bash scripts of the same names: those are
# obsolete and are being removed from qemu-minimal, so anything calling them
# breaks on the next pin bump. Run from the repo root.
#
# This looks for *invocations*, not mentions -- either a path ending in the
# script name, or the bare name in command position. Prose such as
# "qemu-tool gen-vm" is fine, and so is naming the obsolete scripts in a
# comment that explains why they are obsolete.

pattern='(^|[;&|(]|\$\()[[:space:]]*(gen-vm|run-vm)\b|[[:alnum:]_.{}"'"'"'/-]+/(gen-vm|run-vm)\b'

hits=$(grep -rnE --binary-files=without-match \
    --exclude-dir=.git \
    --exclude-dir=.venv \
    --exclude-dir=__pycache__ \
    --exclude=.wordlist.txt \
    --exclude="$(basename "$0")" \
    "$pattern" . || true)

if [ -n "$hits" ]; then
    echo "ERROR: direct gen-vm / run-vm invocation; use 'qemu-tool gen-vm'" \
         "or 'qemu-tool run-vm' instead:"
    echo "$hits"
    exit 1
fi

echo "OK: no direct gen-vm / run-vm invocations"
