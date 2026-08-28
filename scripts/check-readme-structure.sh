#!/usr/bin/env bash
set -euo pipefail

readme="README.md"
fail=0

# Every directory containing a Dockerfile must appear in the README
# Project Structure section. Run from the repo root.
while IFS= read -r dockerfile; do
    dir=$(dirname "$dockerfile" | sed 's|^\./||')
    if ! grep -qF "${dir}/" "$readme"; then
        echo "ERROR: '${dir}/' has a Dockerfile but is missing from ${readme} Project Structure"
        fail=1
    fi
done < <(find . -maxdepth 2 -name "Dockerfile" -type f | sort)

if [ "$fail" -eq 0 ]; then
    echo "OK: all image directories are documented in ${readme}"
fi
exit "$fail"
