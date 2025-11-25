#!/bin/bash
#
# build-vm.sh
#
# Script to build QEMU and create VM image using qemu-minimal gen-vm
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
QEMU_MINIMAL_COMMIT=${QEMU_MINIMAL_COMMIT:-}

echo "Building VM: ${VM_NAME}"
echo "Username: ${USERNAME}"
echo "QEMU Path: ${QEMU_PATH}"

# Display QEMU commit used
if [ -f /build/qemu-commit.txt ]; then
    QEMU_COMMIT=$(cat /build/qemu-commit.txt)
    echo "QEMU Commit: ${QEMU_COMMIT}"
fi

# Check if qemu-minimal exists or needs to be cloned
if [ ! -d "${QEMU_MINIMAL_PATH}" ]; then
    if [ -z "${QEMU_MINIMAL_REPO}" ]; then
        echo "Error: qemu-minimal directory not found at ${QEMU_MINIMAL_PATH}"
        echo "Please mount it as a volume or set QEMU_MINIMAL_REPO"
        exit 1
    fi
    
    echo "Cloning qemu-minimal repository..."
    git clone "${QEMU_MINIMAL_REPO}" "${QEMU_MINIMAL_PATH}"
    
    if [ -n "${QEMU_MINIMAL_COMMIT}" ]; then
        echo "Checking out qemu-minimal at commit: ${QEMU_MINIMAL_COMMIT}"
        cd "${QEMU_MINIMAL_PATH}"
        git checkout "${QEMU_MINIMAL_COMMIT}"
        git rev-parse HEAD > /build/qemu-minimal-commit.txt
        echo "qemu-minimal Commit: $(cat /build/qemu-minimal-commit.txt)"
    fi
else
    # Verify it's a git repository
    if [ ! -d "${QEMU_MINIMAL_PATH}/.git" ]; then
        echo "Error: ${QEMU_MINIMAL_PATH} exists but is not a git repository"
        exit 1
    fi
    
    # If directory exists, check out specific commit if provided
    if [ -n "${QEMU_MINIMAL_COMMIT}" ]; then
        echo "Checking out qemu-minimal at commit: ${QEMU_MINIMAL_COMMIT}"
        cd "${QEMU_MINIMAL_PATH}"
        CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [ -z "${CURRENT_COMMIT}" ] || [ "${CURRENT_COMMIT}" != "${QEMU_MINIMAL_COMMIT}" ]; then
            git fetch origin 2>/dev/null || true
            git checkout "${QEMU_MINIMAL_COMMIT}"
            VERIFIED_COMMIT=$(git rev-parse HEAD)
            echo "${VERIFIED_COMMIT}" > /build/qemu-minimal-commit.txt
            echo "qemu-minimal Commit: ${VERIFIED_COMMIT}"
        else
            echo "qemu-minimal already at commit: ${CURRENT_COMMIT}"
            echo "${CURRENT_COMMIT}" > /build/qemu-minimal-commit.txt
        fi
    else
        CURRENT_COMMIT=$(cd "${QEMU_MINIMAL_PATH}" && git rev-parse HEAD)
        echo "qemu-minimal Commit: ${CURRENT_COMMIT}"
        echo "${CURRENT_COMMIT}" > /build/qemu-minimal-commit.txt
    fi
fi

# Create images directory if it doesn't exist
mkdir -p "${QEMU_MINIMAL_PATH}/images"

# Generate SSH key if it doesn't exist
if [ ! -f /root/.ssh/id_rsa.pub ]; then
    mkdir -p /root/.ssh
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
fi

# Change to qemu-minimal qemu directory
cd "${QEMU_MINIMAL_PATH}/qemu"

# Set environment variables for gen-vm
export QEMU_PATH=${QEMU_PATH}
export VM_NAME=${VM_NAME}
export USERNAME=${USERNAME}
export PASS=${PASSWORD}
export IMAGES=${QEMU_MINIMAL_PATH}/images
export RELEASE=noble
export ARCH=amd64

# Run gen-vm to create the VM
echo "Running gen-vm to create VM image..."
./gen-vm

# Copy the VM image to output directory
if [ -f "${IMAGES}/${VM_NAME}.qcow2" ]; then
    echo "Copying VM image to output directory..."
    cp "${IMAGES}/${VM_NAME}.qcow2" /output/
    if [ -f "${IMAGES}/${VM_NAME}-backing.qcow2" ]; then
        cp "${IMAGES}/${VM_NAME}-backing.qcow2" /output/
    fi
    echo "VM image created successfully: /output/${VM_NAME}.qcow2"
else
    echo "Error: VM image was not created!"
    exit 1
fi

