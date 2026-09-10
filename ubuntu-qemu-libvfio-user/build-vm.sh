#!/bin/sh
#
# build-vm.sh
#
# Build the CI VM disk image with "qemu-tool gen-vm" and write
# /output/vm-info.json.  Run from the Dockerfile; configuration
# comes from the build ARGs, which reach us as environment
# variables.  A no-op when qemu-minimal was not cloned.
#
# KVM is mandatory.  It only works in a RUN --security=insecure
# step (the device node has to be created and opened); anywhere
# else this script aborts rather than fall back to TCG emulation,
# which is roughly 10x slower.
#

set -eu

QM=/build/qemu-minimal

if [ ! -d "${QM}" ]; then
    echo "No qemu-minimal, skipping VM build"
    exit 0
fi

FINAL_USERNAME="${USERNAME:-batesste}"
FINAL_VM_NAME="${VM_NAME:-${FINAL_USERNAME}-ci-vm}"
FINAL_PASSWORD="${PASSWORD:-changeme}"
FINAL_RELEASE="${RELEASE:-resolute}"
FINAL_ARCH="${ARCH:-amd64}"
FINAL_VM_SIZE="${VM_SIZE:-64}"
KERNEL_VERSION=$(uname -r)

echo "=== VM Build Configuration ==="
echo "Cache-bust: ${CACHE_BUST:-none}"
echo "QEMU_MINIMAL_REPO: ${QEMU_MINIMAL_REPO:-}"
echo "QEMU_MINIMAL_COMMIT: ${QEMU_MINIMAL_COMMIT:-HEAD}"
echo "VM_NAME: ${FINAL_VM_NAME}"
echo "USERNAME: ${FINAL_USERNAME}"
echo "RELEASE: ${FINAL_RELEASE}"
echo "ARCH: ${FINAL_ARCH}"
echo "VM_SIZE: ${FINAL_VM_SIZE}G"
echo "Kernel version: ${KERNEL_VERSION}"

command -v qemu-tool > /dev/null || {
    echo "Error: qemu-tool not installed!"
    exit 1
}

mkdir -p "${QM}/images"
cp /tmp/cloud-cache/*.img "${QM}/images/" 2>/dev/null || true

# /dev/kvm does not exist in the build sandbox, so create it.  Both
# the mknod and the open fail without the insecure entitlement, and
# that is fatal: there is no TCG fallback.
[ -e /dev/kvm ] || mknod /dev/kvm c 10 232 2>/dev/null || true
chmod 666 /dev/kvm 2>/dev/null || true
if ! { [ -c /dev/kvm ] && (exec 3<> /dev/kvm); } 2>/dev/null; then
    echo "Error: /dev/kvm is unusable inside this build step."
    echo "  Build the image with 'docker buildx build --allow" \
         "security.insecure' against a builder created with"
    echo "  --buildkitd-flags '--allow-insecure-entitlement" \
         "security.insecure', on an x86 host with KVM enabled."
    exit 1
fi

# Extra packages from packages.txt are appended to qemu-minimal's
# default cloud-init manifest, one "  - name" entry per line.
PACKAGES_FILE="${QM}/qemu/packages.d/packages-default"
if [ -f /build/packages.txt ]; then
    COMBINED=/tmp/packages-combined
    if [ -f "${PACKAGES_FILE}" ]; then
        cat "${PACKAGES_FILE}" > "${COMBINED}"
    else
        echo "# Packages from packages.txt" > "${COMBINED}"
    fi
    echo "# Additional packages from packages.txt" >> "${COMBINED}"
    sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" \
        /build/packages.txt |
        grep -v '^#' | grep -v '^$' |
        sed 's/^/  - /' >> "${COMBINED}"
    PACKAGES_FILE="${COMBINED}"
fi

echo "Running qemu-tool gen-vm --kvm..."
qemu-tool gen-vm \
    --vm-name "${FINAL_VM_NAME}" \
    --username "${FINAL_USERNAME}" \
    --password "${FINAL_PASSWORD}" \
    --release "${FINAL_RELEASE}" \
    --arch "${FINAL_ARCH}" \
    --size "${FINAL_VM_SIZE}" \
    --images "${QM}/images" \
    --qemu-path /opt/qemu/bin/ \
    --ssh-key-file /root/.ssh/id_rsa.pub \
    --packages "${PACKAGES_FILE}" \
    --no-backing \
    --kvm

[ -f "${QM}/images/${FINAL_VM_NAME}.qcow2" ] || {
    echo "Error: VM image not created!"
    ls -la "${QM}/images/"
    exit 1
}

cp "${QM}/images/${FINAL_VM_NAME}.qcow2" /output/
cp /root/.ssh/id_rsa /output/id_rsa 2>/dev/null || true
cp /root/.ssh/id_rsa.pub /output/id_rsa.pub 2>/dev/null || true

QEMU_COMMIT_INFO=$(cat /build/qemu-commit.txt 2>/dev/null \
    || echo "unknown")
LIBVFIO_USER_COMMIT_INFO=$(cat /build/libvfio-user-commit.txt \
    2>/dev/null || echo "unknown")
QEMU_MINIMAL_COMMIT_INFO=$(cat /build/qemu-minimal-commit.txt \
    2>/dev/null || echo "unknown")
IMAGE_SIZE=$(stat -c%s "/output/${FINAL_VM_NAME}.qcow2" \
    2>/dev/null || echo "0")
IMAGE_FORMAT=$(/opt/qemu/bin/qemu-img info \
    "/output/${FINAL_VM_NAME}.qcow2" 2>/dev/null |
    grep -i "file format" | cut -d: -f2 | xargs || echo "qcow2")
BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > /output/vm-info.json <<EOF
{
  "vm_name": "${FINAL_VM_NAME}",
  "username": "${FINAL_USERNAME}",
  "password": "${FINAL_PASSWORD}",
  "image_path": "/output/${FINAL_VM_NAME}.qcow2",
  "image_format": "${IMAGE_FORMAT}",
  "image_size_bytes": ${IMAGE_SIZE},
  "release": "${FINAL_RELEASE}",
  "architecture": "${FINAL_ARCH}",
  "qemu_path": "/opt/qemu/bin/",
  "kvm_enabled": true,
  "backing_file": false,
  "ssh_keys": {
    "private_key_path": "/output/id_rsa",
    "public_key_path": "/output/id_rsa.pub"
  },
  "build_info": {
    "qemu_commit": "${QEMU_COMMIT_INFO}",
    "libvfio_user_commit": "${LIBVFIO_USER_COMMIT_INFO}",
    "qemu_minimal_commit": "${QEMU_MINIMAL_COMMIT_INFO}",
    "build_timestamp": "${BUILD_TIMESTAMP}"
  }
}
EOF

rm -rf "${QM}"
