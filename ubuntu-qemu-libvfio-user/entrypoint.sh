#!/bin/bash
#
# entrypoint.sh
#
# Entrypoint script to run VM with SSH access
# Note: VM image should be built during Dockerfile build or mounted at runtime
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
QEMU_PATH=${QEMU_PATH:-/opt/qemu/bin/}
SSH_PORT=${SSH_PORT:-2222}
VCPUS=${VCPUS:-2}
VMEM=${VMEM:-4096}

echo "=== VM Container Entrypoint ==="
echo "VM Name: ${VM_NAME}"
echo "Username: ${USERNAME}"
echo "SSH Port: ${SSH_PORT}"
echo "QEMU Path: ${QEMU_PATH}"

# Check for VM image in output directory (built during Dockerfile build)
# or in mounted qemu-minimal directory (runtime mount)
VM_IMAGE=""
if [ -f "/output/${VM_NAME}.qcow2" ]; then
    VM_IMAGE="/output/${VM_NAME}.qcow2"
    echo "VM image found at ${VM_IMAGE}"
elif [ -f "/build/qemu-minimal/images/${VM_NAME}.qcow2" ]; then
    VM_IMAGE="/build/qemu-minimal/images/${VM_NAME}.qcow2"
    echo "VM image found at ${VM_IMAGE}"
else
    echo "Error: VM image not found!"
    echo "Expected at /output/${VM_NAME}.qcow2 or /build/qemu-minimal/images/${VM_NAME}.qcow2"
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

# Attach a vfio-user device server (e.g. rocjitsu, rocm-ernic) when one is named.
# The server reaches guest RAM only through an mmap-able descriptor, so plain
# -m is replaced by a shared memfd backend; without it the device sees no
# guest memory and every DMA fails.
MACHINE_SUFFIX=""
VFIO_USER_ARGS=()
MEMORY_ARGS=(-m "${VMEM}")
if [ -n "${VFIO_USER_SOCKET:-}" ]; then
    if [ "${QARCH}" != "x86_64" ]; then
        echo "Error: VFIO_USER_SOCKET is only supported for ARCH=amd64 (QEMU here is built --target-list=x86_64-softmmu)"
        exit 1
    fi
    echo "Waiting for vfio-user socket at ${VFIO_USER_SOCKET}..."
    # if/fi rather than a && list: set -e is on, and a false AND-list would
    # exit the script instead of looping.
    for _ in $(seq 1 300); do
        if [ -S "${VFIO_USER_SOCKET}" ]; then
            break
        fi
        sleep 0.1
    done
    if [ ! -S "${VFIO_USER_SOCKET}" ]; then
        echo "Error: vfio-user socket ${VFIO_USER_SOCKET} never appeared!"
        exit 1
    fi
    echo "vfio-user socket found, attaching vfio-user-pci"
    MEMORY_ARGS=(
        -object "memory-backend-memfd,id=mem,size=${VMEM}M,share=on"
        -m "${VMEM}"
    )
    MACHINE_SUFFIX=",memory-backend=mem"
    VFIO_USER_ARGS=(
        -device "vfio-user-pci,socket.type=unix,socket.path=${VFIO_USER_SOCKET}"
    )
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
    ${QARCH_ARGS}${MACHINE_SUFFIX}${KVM_ENABLE} \
    -smp "cpus=${VCPUS}" \
    "${MEMORY_ARGS[@]}" \
    -nographic \
    -drive "if=virtio,format=qcow2,file=${VM_IMAGE}" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    ${VFIO_USER_ARGS[@]+"${VFIO_USER_ARGS[@]}"}

