#!/usr/bin/env bash
# Checks upstream versions of pinned dependencies and updates ci-images-tool.py,
# env.example, and the two CI workflow YAMLs. Exits 0 with no changes if everything
# is already current; exits 0 with modified files if updates were applied.
# Intended to be called by .github/workflows/version-scrub.yml and locally.
#
# Requirements: curl, jq, git (for QEMU_MINIMAL HEAD lookup)
# ROCJITSU_COMMIT is intentionally excluded — it tracks a user feature branch and
# requires a human decision before advancing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO_ROOT/ci-images-tool.py"
ENV_EXAMPLE="$REPO_ROOT/env.example"
WORKFLOW_TEST="$REPO_ROOT/.github/workflows/dockerfile-test.yml"
WORKFLOW_RELEASE="$REPO_ROOT/.github/workflows/release.yml"

changed=0

replace_in_files() {
    local old="$1"
    local new="$2"
    shift 2
    for f in "$@"; do
        if grep -qF "$old" "$f"; then
            sed -i "s|${old}|${new}|g" "$f"
            echo "  updated $(basename "$f"): $old -> $new"
            changed=1
        fi
    done
}

echo "==> Fetching latest QEMU release tag..."
QEMU_LATEST=$(curl -fsSL \
    "https://gitlab.com/api/v4/projects/qemu-project%2Fqemu/releases?per_page=1" \
    | jq -r '.[0].tag_name')
QEMU_CURRENT=$(grep -oP 'DEFAULT_QEMU_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $QEMU_CURRENT  latest: $QEMU_LATEST"
if [[ "$QEMU_CURRENT" != "$QEMU_LATEST" ]]; then
    replace_in_files "$QEMU_CURRENT" "$QEMU_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE"
fi

echo "==> Fetching latest libvfio-user HEAD..."
LIBVFIO_LATEST=$(curl -fsSL \
    "https://gitlab.com/api/v4/projects/qemu-project%2Flibvfio-user/repository/commits/master" \
    | jq -r '.id')
LIBVFIO_CURRENT=$(grep -oP 'DEFAULT_LIBVFIO_USER_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $LIBVFIO_CURRENT  latest: $LIBVFIO_LATEST"
if [[ "$LIBVFIO_CURRENT" != "$LIBVFIO_LATEST" ]]; then
    replace_in_files "$LIBVFIO_CURRENT" "$LIBVFIO_LATEST" \
        "$TOOL" "$ENV_EXAMPLE" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE" \
        "$REPO_ROOT/ubuntu-rocm-ernic/Dockerfile" \
        "$REPO_ROOT/ubuntu-qemu-libvfio-user/Dockerfile"
fi

echo "==> Fetching latest ROCM_ERNIC HEAD..."
ERNIC_LATEST=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "https://api.github.com/repos/ROCm/rocm-ernic/commits/HEAD" \
    | jq -r '.sha')
ERNIC_CURRENT=$(grep -oP 'DEFAULT_ROCM_ERNIC_COMMIT\s*=\s*"\K[^"]+' "$TOOL")
echo "    current: $ERNIC_CURRENT  latest: $ERNIC_LATEST"
if [[ "$ERNIC_CURRENT" != "$ERNIC_LATEST" ]]; then
    replace_in_files "$ERNIC_CURRENT" "$ERNIC_LATEST" \
        "$TOOL" "$WORKFLOW_TEST" "$WORKFLOW_RELEASE" \
        "$REPO_ROOT/ubuntu-rocm-ernic/Dockerfile"
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
if [[ -n "$KEYRING_LATEST" && "$KEYRING_CURRENT" != "$KEYRING_LATEST" ]]; then
    replace_in_files "$KEYRING_CURRENT" "$KEYRING_LATEST" \
        "$REPO_ROOT/ubuntu-cuda-rocm/Dockerfile"
fi

if [[ "$changed" -eq 0 ]]; then
    echo "==> All versions are current, no changes needed."
else
    echo "==> Version scrub complete. Files modified."
fi
