#!/bin/sh
# Echo back only those -D options the meson project rooted at $1 declares.
#
# NIXL's release branches trail main by whole meson options -- v1.4.1 has no
# rocm_path at the top level, and its nixlbench has neither ucx_path nor
# build_raw_cli -- and meson aborts on an unknown -D rather than ignoring it.
# Filtering lets one Dockerfile serve both a release tag and main, so a
# nixl_tag bump neither breaks the build nor silently drops an option a newer
# tree does support. Dropped options are reported on stderr so a typo shows up
# in the build log instead of passing unnoticed.
#
# Usage: meson-supported-opts.sh <source-dir> -Dfoo=1 -Dbar=2 ...
set -eu

src="$1"
shift

opts_file=""
for candidate in "${src}/meson_options.txt" "${src}/meson.options"; do
    if [ -f "$candidate" ]; then
        opts_file="$candidate"
        break
    fi
done

# No declarations to check against: hand everything back and let meson rule.
if [ -z "$opts_file" ]; then
    for opt in "$@"; do
        printf '%s\n' "$opt"
    done
    exit 0
fi

for opt in "$@"; do
    name="${opt#-D}"
    name="${name%%=*}"
    if grep -q "^option('${name}'" "$opts_file"; then
        printf '%s\n' "$opt"
    else
        echo "meson-supported-opts: ${src} does not declare '${name}', dropping ${opt}" >&2
    fi
done
