#!/bin/sh
#
# build-vm.sh
#
# Build one guest qcow2 with "qemu-tool gen-vm" and write /output/vm-info.json.
# Run from the Dockerfile; configuration comes from the build ARGs, which reach
# us as environment variables.
#
# Two provisioning layers, matching how the container images work:
#   packages/<VM_PACKAGES>  cloud-init packages, appended to qemu-minimal's
#                           default manifest
#   <VM_PLAYBOOK>           an Ansible playbook from the qemu-minimal checkout,
#                           for anything cloud-init cannot express
#
# KVM is mandatory.  It only works in a RUN --security=insecure step (the
# device node has to be created and opened); anywhere else this script aborts
# rather than fall back to TCG emulation, which is roughly 10x slower.
#

set -eu

QM=/build/qemu-minimal
CTX=/ctx/common

FLAVOUR="${FLAVOUR:-basic}"
FINAL_USERNAME="${USERNAME:-batesste}"
FINAL_VM_NAME="${VM_NAME:-${FINAL_USERNAME}-ci-vm}"
FINAL_PASSWORD="${PASSWORD:-changeme}"
FINAL_RELEASE="${RELEASE:-resolute}"
FINAL_ARCH="${ARCH:-amd64}"
FINAL_VM_SIZE="${VM_SIZE:-64}"
FINAL_PACKAGES="${VM_PACKAGES:-base.txt}"
FINAL_PLAYBOOK="${VM_PLAYBOOK:-}"
KERNEL_VERSION=$(uname -r)

echo "=== Guest Image Build Configuration ==="
echo "Cache-bust: ${CACHE_BUST:-none}"
echo "FLAVOUR: ${FLAVOUR}"
echo "QEMU_MINIMAL_REPO: ${QEMU_MINIMAL_REPO:-}"
echo "QEMU_MINIMAL_COMMIT: ${QEMU_MINIMAL_COMMIT:-HEAD}"
echo "VM_NAME: ${FINAL_VM_NAME}"
echo "USERNAME: ${FINAL_USERNAME}"
echo "RELEASE: ${FINAL_RELEASE}"
echo "ARCH: ${FINAL_ARCH}"
echo "VM_SIZE: ${FINAL_VM_SIZE}G"
echo "VM_PACKAGES: ${FINAL_PACKAGES}"
echo "VM_PLAYBOOK: ${FINAL_PLAYBOOK:-none}"

command -v qemu-tool > /dev/null || {
    echo "Error: qemu-tool not installed!"
    exit 1
}

# /dev/kvm does not exist in the build sandbox, so create it.  Both the mknod
# and the open fail without the insecure entitlement, and that is fatal: there
# is no TCG fallback.
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

mkdir -p "${QM}/images"
cp "${CTX}"/cloud-image-cache/*.img "${QM}/images/" 2>/dev/null || true

# Extra packages are appended to qemu-minimal's default cloud-init manifest,
# one "  - name" entry per line.  ${KERNEL_VERSION} expands to the *host*
# kernel, so a manifest wanting guest-kernel-matched packages should name the
# -generic metapackages instead; the substitution is kept for the few cases
# where host and guest kernels really do have to agree.
PACKAGES_FILE="${QM}/qemu/packages.d/packages-default"
EXTRA="/build/packages/${FINAL_PACKAGES}"
PACKAGES_DIGEST=none
if [ -n "${FINAL_PACKAGES}" ] && [ "${FINAL_PACKAGES}" != "none" ]; then
    [ -f "${EXTRA}" ] || {
        echo "Error: package manifest ${EXTRA} does not exist!"
        ls -la /build/packages/
        exit 1
    }
    PACKAGES_DIGEST=$(sha256sum "${EXTRA}" | cut -d' ' -f1)
    COMBINED=/tmp/packages-combined
    if [ -f "${PACKAGES_FILE}" ]; then
        cat "${PACKAGES_FILE}" > "${COMBINED}"
    else
        echo "# Packages for the ${FLAVOUR} guest" > "${COMBINED}"
    fi
    echo "# Additional packages from ${FINAL_PACKAGES}" >> "${COMBINED}"
    sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" "${EXTRA}" |
        grep -v '^#' | grep -v '^$' |
        sed 's/^/  - /' >> "${COMBINED}"
    PACKAGES_FILE="${COMBINED}"
fi

set -- \
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

if [ -n "${FINAL_PLAYBOOK}" ]; then
    PLAYBOOK="${QM}/ansible/playbooks/${FINAL_PLAYBOOK}"
    [ -f "${PLAYBOOK}" ] || {
        echo "Error: playbook ${PLAYBOOK} does not exist!"
        ls -la "${QM}/ansible/playbooks/" 2>/dev/null || true
        exit 1
    }
    set -- "$@" --ansible-playbook "${PLAYBOOK}"
fi

# ZScaler on the AMD network re-signs TLS, so the guest needs the corporate
# root CA for in-guest apt and git to work.  Gitignored and absent in CI.
if [ -f "${CTX}/amd-root-ca.crt" ]; then
    echo "Injecting AMD root CA into the guest trust store"
    set -- "$@" --ca-cert "${CTX}/amd-root-ca.crt"
fi

echo "Running qemu-tool gen-vm $*"
qemu-tool gen-vm "$@"

IMAGE="${QM}/images/${FINAL_VM_NAME}.qcow2"
[ -f "${IMAGE}" ] || {
    echo "Error: VM image not created!"
    ls -la "${QM}/images/"
    exit 1
}

cp "${IMAGE}" /output/
cp /root/.ssh/id_rsa /output/id_rsa
cp /root/.ssh/id_rsa.pub /output/id_rsa.pub
chmod 600 /output/id_rsa

# Boot the finished guest once, to read its kernel out of it and to run the
# flavour's checks.  The kernel version is not knowable before the build --
# which is why it is not in the image tag -- and consumers that need a minimum
# (ionic RDMA needs >= 6.18) should not have to boot the image to find out.
# The same boot verifies the guest: one that cannot come up over SSH, or that
# is missing what its flavour promised, fails the build rather than the
# consumer.  Checks live beside the package manifests, so a new flavour is a
# packages file plus a checks file plus an images.yml variant.
PROBE=/tmp/probe.sh
cat > "${PROBE}" <<'PROBE_EOF'
set -eu
printf 'PROBE_KERNEL=%s\n' "$(uname -r)"
# Passwordless sudo and sshd on 22 are the contract for every flavour, so they
# are asserted here rather than repeated in each checks file.
sudo -n true
PROBE_EOF

CHECKS="/build/checks/${FLAVOUR}.sh"
if [ -f "${CHECKS}" ]; then
    printf 'echo "Running %s checks" >&2\n' "${FLAVOUR}" >> "${PROBE}"
    cat "${CHECKS}" >> "${PROBE}"
else
    printf 'echo "No checks file for flavour %s" >&2\n' "${FLAVOUR}" >> "${PROBE}"
fi
echo 'echo PROBE_OK' >> "${PROBE}"

PROBE_OUT=$(probe-guest "/output/${FINAL_VM_NAME}.qcow2" "${FINAL_USERNAME}" \
    "${PROBE}")
printf '%s\n' "${PROBE_OUT}"
echo "${PROBE_OUT}" | grep -qx 'PROBE_OK' || {
    echo "Error: guest checks did not complete"
    exit 1
}
GUEST_KERNEL=$(echo "${PROBE_OUT}" | sed -n 's/^PROBE_KERNEL=//p')
echo "Guest kernel: ${GUEST_KERNEL}"

QEMU_COMMIT_INFO=$(cat /build/qemu-commit.txt 2>/dev/null || echo "unknown")
LIBVFIO_USER_COMMIT_INFO=$(cat /build/libvfio-user-commit.txt \
    2>/dev/null || echo "unknown")
QEMU_MINIMAL_COMMIT_INFO=$(cat /build/qemu-minimal-commit.txt \
    2>/dev/null || echo "unknown")
IMAGE_SIZE=$(stat -c%s "/output/${FINAL_VM_NAME}.qcow2")
IMAGE_FORMAT=$(/opt/qemu/bin/qemu-img info \
    "/output/${FINAL_VM_NAME}.qcow2" 2>/dev/null |
    grep -i "file format" | cut -d: -f2 | xargs || echo "qcow2")
BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# schema_version 2 adds flavour/kernel_release/vm_playbook/packages_digest on
# top of the v1 keys, all of which are kept so existing consumers are
# unaffected.
cat > /output/vm-info.json <<EOF
{
  "schema_version": 2,
  "vm_name": "${FINAL_VM_NAME}",
  "flavour": "${FLAVOUR}",
  "username": "${FINAL_USERNAME}",
  "password": "${FINAL_PASSWORD}",
  "image_path": "/output/${FINAL_VM_NAME}.qcow2",
  "image_format": "${IMAGE_FORMAT}",
  "image_size_bytes": ${IMAGE_SIZE},
  "release": "${FINAL_RELEASE}",
  "architecture": "${FINAL_ARCH}",
  "kernel_release": "${GUEST_KERNEL}",
  "qemu_path": "/opt/qemu/bin/",
  "kvm_enabled": true,
  "backing_file": false,
  "ssh_keys": {
    "private_key_path": "/output/id_rsa",
    "public_key_path": "/output/id_rsa.pub"
  },
  "provisioning": {
    "vm_packages": "${FINAL_PACKAGES}",
    "packages_digest": "${PACKAGES_DIGEST}",
    "vm_playbook": "${FINAL_PLAYBOOK}"
  },
  "build_info": {
    "qemu_commit": "${QEMU_COMMIT_INFO}",
    "libvfio_user_commit": "${LIBVFIO_USER_COMMIT_INFO}",
    "qemu_minimal_commit": "${QEMU_MINIMAL_COMMIT_INFO}",
    "build_timestamp": "${BUILD_TIMESTAMP}"
  }
}
EOF

cat /output/vm-info.json
rm -rf "${QM}"
