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
# or in mounted qemu-minimal directory (runtime mount).
#
# qemu-tool takes the directory and the name separately, so the directory the
# guest was found in is what gets carried forward rather than the full path.
VM_IMAGE=""
VM_IMAGES_DIR=""
if [ -f "/output/${VM_NAME}.qcow2" ]; then
    VM_IMAGES_DIR="/output"
    VM_IMAGE="/output/${VM_NAME}.qcow2"
    echo "VM image found at ${VM_IMAGE}"
elif [ -f "/build/qemu-minimal/images/${VM_NAME}.qcow2" ]; then
    VM_IMAGES_DIR="/build/qemu-minimal/images"
    VM_IMAGE="/build/qemu-minimal/images/${VM_NAME}.qcow2"
    echo "VM image found at ${VM_IMAGE}"
else
    echo "Error: VM image not found!"
    echo "Expected at /output/${VM_NAME}.qcow2 or /build/qemu-minimal/images/${VM_NAME}.qcow2"
    exit 1
fi

ARCH=${ARCH:-amd64}

# Attach a vfio-user device server (e.g. rocjitsu, rocm-ernic) when one is
# named. The socket belongs to another container in the stack, which compose
# starts concurrently, so it has to be waited for here -- qemu-tool does not
# wait, it just fails to connect.
VFIO_USER_ARGS=()
if [ -n "${VFIO_USER_SOCKET:-}" ]; then
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
    VFIO_USER_ARGS=(--vfio-userdev "${VFIO_USER_SOCKET}")
fi

# Check if KVM is available (optional, will use TCG if not)
KVM_ARG="--no-kvm"
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ARG="--kvm"
    echo "KVM acceleration enabled"
else
    echo "KVM not available, using TCG emulation"
fi

echo "Starting VM..."
echo "SSH will be available on port ${SSH_PORT}"
echo "Connect with: ssh -p ${SSH_PORT} ${USERNAME}@localhost"

# Delegated to qemu-tool rather than spelled out here. This script used to
# build its own qemu-system command line -- it predates qemu-tool being in the
# image at all -- and it rotted where nobody looked: the vfio-user device was
# attached as "vfio-user-pci,socket.type=unix,socket.path=...", a spelling no
# QEMU in this image accepts, so every guest booted this way died instantly on
# "Property 'vfio-user-pci.socket.type' not found". socket is a compound
# property and only the JSON -device form can set it, which is what qemu-tool
# emits. compose/perf-stack.yml had already stopped using this path for its
# own reasons, which is why the breakage went unnoticed.
#
# There is one spelling of a QEMU command line in this stack now, and it comes
# from the qemu-minimal SHA the image is pinned to -- the same one the guests
# are built with.
#
# --qemu-path is load-bearing: without it qemu-tool resolves qemu-system-* off
# PATH, which is not the libvfio-user-enabled build under /opt/qemu that this
# image exists to provide.
exec qemu-tool run-vm \
    --images "${VM_IMAGES_DIR}" \
    --vm-name "${VM_NAME}" \
    --arch "${ARCH}" \
    --vcpus "${VCPUS}" \
    --vmem "${VMEM}" \
    --ssh-port "${SSH_PORT}" \
    --qemu-path "${QEMU_PATH}" \
    "${KVM_ARG}" \
    ${VFIO_USER_ARGS[@]+"${VFIO_USER_ARGS[@]}"}

