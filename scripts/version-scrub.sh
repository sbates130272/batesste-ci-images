#!/usr/bin/env bash
# Checks upstream versions of pinned dependencies and updates ci-images-tool.py,
# env.example, and the two CI workflow YAMLs. Exits 0 with no changes if everything
# is already current; exits 0 with modified files if updates were applied.
# Intended to be called by .github/workflows/version-scrub.yml and locally.
#
# Requirements: curl, jq, git (for QEMU_MINIMAL HEAD lookup)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO_ROOT/ci-images-tool.py"
ENV_EXAMPLE="$REPO_ROOT/env.example"
WORKFLOW_TEST="$REPO_ROOT/.github/workflows/dockerfile-test.yml"
WORKFLOW_RELEASE="$REPO_ROOT/.github/workflows/release.yml"

changed=0

# Abort if a fetched value is empty or null — better to skip than corrupt.
check_nonempty() {
    local val="$1" label="$2"
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "  WARNING: could not fetch $label (got: '$val'), skipping."
        return 1
    fi
    return 0
}

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
QEMU_CURRENT=$(grep -oP 'DEFAULT_QEMU_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $QEMU_CURRENT  latest: $QEMU_LATEST"
if check_nonempty "$QEMU_LATEST" "QEMU tag" && [[ "$QEMU_CURRENT" != "$QEMU_LATEST" ]]; then
    replace_in_files "$QEMU_CURRENT" "$QEMU_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE"
fi

echo "==> Fetching latest libvfio-user HEAD..."
LIBVFIO_LATEST=$(curl -fsSL \
    "https://gitlab.com/api/v4/projects/qemu-project%2Flibvfio-user/repository/commits/master" \
    | jq -r '.id')
LIBVFIO_CURRENT=$(grep -oP 'DEFAULT_LIBVFIO_USER_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $LIBVFIO_CURRENT  latest: $LIBVFIO_LATEST"
if check_nonempty "$LIBVFIO_LATEST" "libvfio-user HEAD" && [[ "$LIBVFIO_CURRENT" != "$LIBVFIO_LATEST" ]]; then
    replace_in_files "$LIBVFIO_CURRENT" "$LIBVFIO_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE" \
        "$REPO_ROOT/ubuntu-rocm-ernic/Dockerfile" \
        "$REPO_ROOT/ubuntu-qemu-libvfio-user/Dockerfile"
fi

echo "==> Fetching latest qemu-minimal HEAD..."
QEMU_MINIMAL_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/sbates130272/qemu-minimal/commits/main" \
    | jq -r '.sha')
QEMU_MINIMAL_CURRENT=$(grep -oP 'DEFAULT_QEMU_MINIMAL_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $QEMU_MINIMAL_CURRENT  latest: $QEMU_MINIMAL_LATEST"
if check_nonempty "$QEMU_MINIMAL_LATEST" "qemu-minimal HEAD" \
    && [[ "$QEMU_MINIMAL_CURRENT" != "$QEMU_MINIMAL_LATEST" ]]; then
    replace_in_files "$QEMU_MINIMAL_CURRENT" "$QEMU_MINIMAL_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE"
fi

echo "==> Fetching latest ROCM_ERNIC HEAD..."
ERNIC_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/ROCm/rocm-ernic/commits/HEAD" \
    | jq -r '.sha')
ERNIC_CURRENT=$(grep -oP 'DEFAULT_ROCM_ERNIC_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $ERNIC_CURRENT  latest: $ERNIC_LATEST"
if check_nonempty "$ERNIC_LATEST" "ROCM_ERNIC HEAD" && [[ "$ERNIC_CURRENT" != "$ERNIC_LATEST" ]]; then
    replace_in_files "$ERNIC_CURRENT" "$ERNIC_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE" \
        "$REPO_ROOT/ubuntu-rocm-ernic/Dockerfile"
fi

echo "==> Fetching latest ROCJITSU HEAD..."
# Track whichever branch the tool is pinned to rather than hardcoding it here.
ROCJITSU_BRANCH=$(grep -oP 'DEFAULT_ROCM_ROCJITSU_BRANCH\s*=\s*"\K[^"]+' "$TOOL")
ROCJITSU_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/ROCm/rocm-systems/commits/${ROCJITSU_BRANCH}" \
    | jq -r '.sha')
ROCJITSU_CURRENT=$(grep -oP 'DEFAULT_ROCM_ROCJITSU_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $ROCJITSU_CURRENT  latest: $ROCJITSU_LATEST  (branch: $ROCJITSU_BRANCH)"
if check_nonempty "$ROCJITSU_LATEST" "ROCJITSU HEAD" \
    && [[ "$ROCJITSU_CURRENT" != "$ROCJITSU_LATEST" ]]; then
    replace_in_files "$ROCJITSU_CURRENT" "$ROCJITSU_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE" \
        "$REPO_ROOT/ubuntu-rocm-rocjitsu/Dockerfile"
fi

echo "==> Fetching latest fio HEAD..."
# fio must track master: the libhipfile engine is not in any release tag yet.
FIO_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/axboe/fio/commits/HEAD" \
    | jq -r '.sha')
FIO_CURRENT=$(grep -oP 'DEFAULT_FIO_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $FIO_CURRENT  latest: $FIO_LATEST"
if check_nonempty "$FIO_LATEST" "fio HEAD" && [[ "$FIO_CURRENT" != "$FIO_LATEST" ]]; then
    replace_in_files "$FIO_CURRENT" "$FIO_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE" \
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
