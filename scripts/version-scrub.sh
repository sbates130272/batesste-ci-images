#!/usr/bin/env bash
# Checks upstream versions of pinned dependencies and updates images.yml plus
# the matching Dockerfile ARG fallbacks. Exits 0 with no changes if everything
# is already current; exits 0 with modified files if updates were applied.
# Intended to be called by .github/workflows/version-scrub.yml and locally.
#
# images.yml is the single source of truth for pins, so the current value is
# read back through the tool rather than grepped out of Python constants. The
# Dockerfile ARG defaults are only the standalone-`docker build` fallback, but
# they are kept in step so the two never disagree.
#
# Variant pins are deliberately excluded: a variant exists precisely to sit at
# a ref of its own, so bumping it to branch HEAD would defeat it.
#
# Requirements: curl, jq, python3 (for the tool)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO_ROOT/ci-images-tool.py"
IMAGES_YML="$REPO_ROOT/images.yml"

changed=0

# Read a pin the way every other consumer does, with the environment ignored:
# a stray .env must not make the scrub think the checked-in pin is something
# it is not, and then rewrite the wrong literal.
current_pin() {
    local target="$1" var="$2"
    "$TOOL" config "$target" --get "$var" --env-file /dev/null
}

# Abort if a fetched value is empty or null — better to skip than corrupt.
check_nonempty() {
    local val="$1" label="$2"
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "  WARNING: could not fetch $label (got: '$val'), skipping."
        return 1
    fi
    return 0
}

# Replace a literal in images.yml everywhere *except* inside a `variants:`
# block. Image keys sit at two spaces and their fields at four, so a variants
# block runs from its own line until the next line indented four spaces or
# less.
replace_in_yaml() {
    local old="$1" new="$2"
    if ! grep -qF "$old" "$IMAGES_YML"; then
        echo "  WARNING: images.yml does not contain $old" \
             "— it is pinned to something else and is no longer tracked."
        return
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v old="$old" -v new="$new" '
        /^    variants:[[:space:]]*$/ { in_variants = 1; print; next }
        in_variants && /^[[:space:]]*$/ { print; next }
        in_variants && !/^     / { in_variants = 0 }
        {
            if (!in_variants) gsub(old, new)
            print
        }
    ' "$IMAGES_YML" > "$tmp"
    if cmp -s "$tmp" "$IMAGES_YML"; then
        rm -f "$tmp"
        echo "  WARNING: $old appears only inside a variants: block" \
             "— leaving it pinned."
        return
    fi
    mv "$tmp" "$IMAGES_YML"
    echo "  updated images.yml: $old -> $new"
    changed=1
}

# The Dockerfile ARG default is the fallback for a bare `docker build`; keep it
# aligned with images.yml so the two cannot drift apart silently.
replace_in_files() {
    local old="$1"
    local new="$2"
    shift 2
    for f in "$@"; do
        if grep -qF "$old" "$f"; then
            sed -i "s|${old}|${new}|g" "$f"
            echo "  updated $(basename "$f"): $old -> $new"
            changed=1
        else
            # A listed file that lacks the current value has drifted off the
            # scrub: the literal replace will never match it again. Silence
            # here is how ernic's Dockerfile and env.example went stale.
            echo "  WARNING: $(basename "$f") does not contain $old" \
                 "— it is pinned to something else and is no longer tracked."
        fi
    done
}

echo "==> Fetching latest QEMU release tag..."
# Use the tags API sorted by version; releases API can return empty for QEMU.
QEMU_LATEST=$(curl -fsSL \
    "https://gitlab.com/api/v4/projects/qemu-project%2Fqemu/repository/tags?per_page=20&order_by=version&sort=desc" \
    | jq -r '[.[] | select(.name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))] | .[0].name')
QEMU_CURRENT=$(current_pin ubuntu-qemu-libvfio-user qemu_commit)
echo "    current: $QEMU_CURRENT  latest: $QEMU_LATEST"
if check_nonempty "$QEMU_LATEST" "QEMU tag" && [[ "$QEMU_CURRENT" != "$QEMU_LATEST" ]]; then
    replace_in_yaml "$QEMU_CURRENT" "$QEMU_LATEST"
fi

echo "==> Fetching latest libvfio-user HEAD..."
LIBVFIO_LATEST=$(curl -fsSL \
    "https://gitlab.com/api/v4/projects/qemu-project%2Flibvfio-user/repository/commits/master" \
    | jq -r '.id')
LIBVFIO_CURRENT=$(current_pin ubuntu-libvfio-user libvfio_user_commit)
echo "    current: $LIBVFIO_CURRENT  latest: $LIBVFIO_LATEST"
if check_nonempty "$LIBVFIO_LATEST" "libvfio-user HEAD" && [[ "$LIBVFIO_CURRENT" != "$LIBVFIO_LATEST" ]]; then
    replace_in_yaml "$LIBVFIO_CURRENT" "$LIBVFIO_LATEST"
    replace_in_files "$LIBVFIO_CURRENT" "$LIBVFIO_LATEST" \
        "$REPO_ROOT/ubuntu-rocm-ernic/Dockerfile" \
        "$REPO_ROOT/ubuntu-qemu-libvfio-user/Dockerfile"
fi

echo "==> Fetching latest qemu-minimal HEAD..."
QEMU_MINIMAL_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/sbates130272/qemu-minimal/commits/main" \
    | jq -r '.sha')
QEMU_MINIMAL_CURRENT=$(current_pin ubuntu-qemu-libvfio-user qemu_minimal_commit)
echo "    current: $QEMU_MINIMAL_CURRENT  latest: $QEMU_MINIMAL_LATEST"
if check_nonempty "$QEMU_MINIMAL_LATEST" "qemu-minimal HEAD" \
    && [[ "$QEMU_MINIMAL_CURRENT" != "$QEMU_MINIMAL_LATEST" ]]; then
    replace_in_yaml "$QEMU_MINIMAL_CURRENT" "$QEMU_MINIMAL_LATEST"
fi

echo "==> Fetching latest ROCM_ERNIC HEAD..."
ERNIC_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/ROCm/rocm-ernic/commits/HEAD" \
    | jq -r '.sha')
ERNIC_CURRENT=$(current_pin ubuntu-rocm-ernic rocm_ernic_commit)
echo "    current: $ERNIC_CURRENT  latest: $ERNIC_LATEST"
if check_nonempty "$ERNIC_LATEST" "ROCM_ERNIC HEAD" && [[ "$ERNIC_CURRENT" != "$ERNIC_LATEST" ]]; then
    replace_in_yaml "$ERNIC_CURRENT" "$ERNIC_LATEST"
    replace_in_files "$ERNIC_CURRENT" "$ERNIC_LATEST" \
        "$REPO_ROOT/ubuntu-rocm-ernic/Dockerfile"
fi

echo "==> Fetching latest ROCJITSU HEAD..."
# Track whichever branch the default target is pinned to rather than
# hardcoding it here.
ROCJITSU_BRANCH=$(current_pin ubuntu-rocm-rocjitsu rocjitsu_branch)
ROCJITSU_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/ROCm/rocm-systems/commits/${ROCJITSU_BRANCH}" \
    | jq -r '.sha')
ROCJITSU_CURRENT=$(current_pin ubuntu-rocm-rocjitsu rocjitsu_commit)
echo "    current: $ROCJITSU_CURRENT  latest: $ROCJITSU_LATEST  (branch: $ROCJITSU_BRANCH)"
if check_nonempty "$ROCJITSU_LATEST" "ROCJITSU HEAD" \
    && [[ "$ROCJITSU_CURRENT" != "$ROCJITSU_LATEST" ]]; then
    replace_in_yaml "$ROCJITSU_CURRENT" "$ROCJITSU_LATEST"
    replace_in_files "$ROCJITSU_CURRENT" "$ROCJITSU_LATEST" \
        "$REPO_ROOT/ubuntu-rocm-rocjitsu/Dockerfile"
fi

echo "==> Fetching latest fio HEAD..."
# fio must track master: the libhipfile engine is not in any release tag yet.
FIO_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/axboe/fio/commits/HEAD" \
    | jq -r '.sha')
FIO_CURRENT=$(current_pin ubuntu-cuda-rocm-fio fio_commit)
echo "    current: $FIO_CURRENT  latest: $FIO_LATEST"
if check_nonempty "$FIO_LATEST" "fio HEAD" && [[ "$FIO_CURRENT" != "$FIO_LATEST" ]]; then
    replace_in_yaml "$FIO_CURRENT" "$FIO_LATEST"
    replace_in_files "$FIO_CURRENT" "$FIO_LATEST" \
        "$REPO_ROOT/ubuntu-cuda-rocm-fio/Dockerfile"
fi

echo "==> Fetching latest cuda-keyring deb..."
KEYRING_PAGE=$(curl -fsSL \
    "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/")
KEYRING_LATEST=$(echo "$KEYRING_PAGE" \
    | grep -oP 'cuda-keyring_[0-9.]+-[0-9]+_all\.deb' \
    | sort -V | tail -1)
KEYRING_CURRENT=$(grep -oP 'cuda-keyring_[0-9.]+-[0-9]+_all\.deb' \
    "$REPO_ROOT/ubuntu-cuda-rocm/Dockerfile" | head -1)
echo "    current: $KEYRING_CURRENT  latest: $KEYRING_LATEST"
if check_nonempty "$KEYRING_LATEST" "cuda-keyring deb" && [[ "$KEYRING_CURRENT" != "$KEYRING_LATEST" ]]; then
    replace_in_files "$KEYRING_CURRENT" "$KEYRING_LATEST" \
        "$REPO_ROOT/ubuntu-cuda-rocm/Dockerfile"
fi

if [[ "$changed" -eq 0 ]]; then
    echo "==> All versions are current, no changes needed."
else
    echo "==> Version scrub complete. Files modified."
fi

# images.yml drives every build, so a scrub that produced an unparseable or
# inconsistent file must fail here rather than in the release run.
if [[ "$changed" -ne 0 ]]; then
    "$TOOL" validate
fi
