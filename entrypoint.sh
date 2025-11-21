#!/bin/bash
#
# entrypoint.sh
#
# Entrypoint script to build VM if needed and run it with SSH access
#

set -e

# Source environment variables from .env if it exists
if [ -f /build/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /build/.env | xargs)
fi

# Set defaults if not provided
USERNAME=${USERNAME:-batesste}
VM_NAME=${VM_NAME:-${USERNAME}-ci-vm}
PASSWORD=${PASSWORD:-changeme}
QEMU_PATH=${QEMU_PATH:-/opt/qemu/bin/}
QEMU_MINIMAL_PATH=${QEMU_MINIMAL_PATH:-/build/qemu-minimal}
SSH_PORT=${SSH_PORT:-2222}
VCPUS=${VCPUS:-2}
VMEM=${VMEM:-4096}

echo "=== VM Container Entrypoint ==="
echo "VM Name: ${VM_NAME}"
echo "Username: ${USERNAME}"
echo "SSH Port: ${SSH_PORT}"
echo "QEMU Path: ${QEMU_PATH}"

# Check if VM image exists, if not build it
VM_IMAGE="${QEMU_MINIMAL_PATH}/images/${VM_NAME}.qcow2"
if [ ! -f "${VM_IMAGE}" ]; then
    echo "VM image not found at ${VM_IMAGE}, building..."
    /build/build-vm.sh
else
    echo "VM image found at ${VM_IMAGE}"
fi

# Verify VM image exists
if [ ! -f "${VM_IMAGE}" ]; then
    echo "Error: VM image not found after build attempt!"
    exit 1
fi

# Set up QEMU architecture
ARCH=${ARCH:-amd64}
if [ "${ARCH}" == "amd64" ]; then
    QARCH="x86_64"
    QARCH_ARGS="-machine q35"
elif [ "${ARCH}" == "arm64" ]; then
    QARCH="aarch64"
    QARCH_ARGS="-machine virt,gic-version=max -cpu max -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
elif [ "${ARCH}" == "riscv64" ]; then
    QARCH="riscv64"
    QARCH_ARGS="-machine virt -kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf"
else
    echo "Error: Unsupported ARCH: ${ARCH}"
    exit 1
fi

# Check if KVM is available (optional, will use TCG if not)
KVM_ENABLE=""
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ENABLE=",accel=kvm"
    echo "KVM acceleration enabled"
else
    echo "KVM not available, using TCG emulation"
fi

# Run QEMU VM
echo "Starting VM..."
echo "SSH will be available on port ${SSH_PORT}"
echo "Connect with: ssh -p ${SSH_PORT} ${USERNAME}@localhost"

# Build QEMU command
# Note: QARCH_ARGS contains multiple space-separated arguments, so we use eval
# shellcheck disable=SC2086
exec "${QEMU_PATH}qemu-system-${QARCH}" \
    ${QARCH_ARGS}${KVM_ENABLE} \
    -smp "cpus=${VCPUS}" \
    -m "${VMEM}" \
    -nographic \
    -drive "if=virtio,format=qcow2,file=${VM_IMAGE}" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0

