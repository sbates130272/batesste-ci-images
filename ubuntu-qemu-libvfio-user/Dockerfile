FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for QEMU and libvfio-user
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    python3 \
    python3-venv \
    ninja-build \
    pkg-config \
    libglib2.0-dev \
    libpixman-1-dev \
    libslirp-dev \
    meson \
    libjson-c-dev \
    libcmocka-dev \
    && rm -rf /var/lib/apt/lists/*

# Accept QEMU and libvfio-user commit hashes as build arguments
ARG QEMU_COMMIT=HEAD
ARG LIBVFIO_USER_COMMIT=HEAD

# Accept qemu-minimal configuration as build arguments
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=noble
ARG ARCH=amd64

# Set working directory
WORKDIR /build

# Clone and build libvfio-user independently
RUN git clone https://gitlab.com/qemu-project/libvfio-user.git /build/libvfio-user && \
    cd /build/libvfio-user && \
    git checkout ${LIBVFIO_USER_COMMIT} && \
    git rev-parse HEAD > /build/libvfio-user-commit.txt && \
    meson setup build && \
    ninja -C build && \
    ninja -C build install && \
    cd /build && \
    rm -rf /build/libvfio-user

# Clone QEMU repository and checkout specific commit
RUN git clone https://gitlab.com/qemu-project/qemu.git /build/qemu && \
    cd /build/qemu && \
    git checkout ${QEMU_COMMIT} && \
    git rev-parse HEAD > /build/qemu-commit.txt

# Build QEMU with slirp networking support
# Note: QEMU will use the system-installed libvfio-user
WORKDIR /build/qemu
RUN ./configure --target-list=x86_64-softmmu \
                --enable-slirp \
                --prefix=/opt/qemu && \
    make -j$(nproc) && \
    make install && \
    cd /build && \
    rm -rf /build/qemu

# Install cloud-init utilities for VM creation
RUN apt-get update && apt-get install -y --no-install-recommends \
    cloud-image-utils \
    qemu-utils \
    wget \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Create output directory for VM images
RUN mkdir -p /output

# Copy packages file for VM customization
COPY packages.txt /build/packages.txt

# Build VM image if qemu-minimal repository is provided
RUN set -eux; \
    if [ -n "${QEMU_MINIMAL_REPO}" ]; then \
        QEMU_MINIMAL_PATH=/build/qemu-minimal; \
        if [ -z "${VM_NAME}" ]; then \
            FINAL_VM_NAME="${USERNAME}-ci-vm"; \
        else \
            FINAL_VM_NAME="${VM_NAME}"; \
        fi; \
        FINAL_USERNAME="${USERNAME:-batesste}"; \
        FINAL_PASSWORD="${PASSWORD:-changeme}"; \
        FINAL_RELEASE="${RELEASE:-noble}"; \
        FINAL_ARCH="${ARCH:-amd64}"; \
        echo "=== VM Build Configuration ==="; \
        echo "QEMU_MINIMAL_REPO: ${QEMU_MINIMAL_REPO}"; \
        echo "QEMU_MINIMAL_COMMIT: ${QEMU_MINIMAL_COMMIT:-HEAD}"; \
        echo "VM_NAME: ${FINAL_VM_NAME}"; \
        echo "USERNAME: ${FINAL_USERNAME}"; \
        echo "RELEASE: ${FINAL_RELEASE}"; \
        echo "ARCH: ${FINAL_ARCH}"; \
        echo "Cloning qemu-minimal repository..."; \
        git clone "${QEMU_MINIMAL_REPO}" "${QEMU_MINIMAL_PATH}" || exit 1; \
        if [ -n "${QEMU_MINIMAL_COMMIT}" ]; then \
            echo "Checking out qemu-minimal at commit: ${QEMU_MINIMAL_COMMIT}"; \
            cd "${QEMU_MINIMAL_PATH}" && \
            git checkout "${QEMU_MINIMAL_COMMIT}" && \
            git rev-parse HEAD > /build/qemu-minimal-commit.txt; \
        else \
            cd "${QEMU_MINIMAL_PATH}" && \
            git rev-parse HEAD > /build/qemu-minimal-commit.txt; \
        fi; \
        echo "Building VM: ${FINAL_VM_NAME}"; \
        mkdir -p "${QEMU_MINIMAL_PATH}/images"; \
        mkdir -p /root/.ssh; \
        if [ ! -f /root/.ssh/id_rsa.pub ]; then \
            ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q; \
        fi; \
        if [ ! -d "${QEMU_MINIMAL_PATH}/qemu" ]; then \
            echo "Error: qemu directory not found in qemu-minimal repo!"; \
            ls -la "${QEMU_MINIMAL_PATH}/" || true; \
            exit 1; \
        fi; \
        cd "${QEMU_MINIMAL_PATH}/qemu" || exit 1; \
        if [ ! -f "./gen-vm" ]; then \
            echo "Error: gen-vm script not found!"; \
            ls -la . || true; \
            exit 1; \
        fi; \
        export QEMU_PATH=/opt/qemu/bin/; \
        export VM_NAME="${FINAL_VM_NAME}"; \
        export USERNAME="${FINAL_USERNAME}"; \
        export PASS="${FINAL_PASSWORD}"; \
        export IMAGES="${QEMU_MINIMAL_PATH}/images"; \
        export RELEASE="${FINAL_RELEASE}"; \
        export ARCH="${FINAL_ARCH}"; \
        export KVM=false; \
        export NO_BACKING=true; \
        KERNEL_VERSION=$(uname -r); \
        echo "Kernel version: ${KERNEL_VERSION}"; \
        EXISTING_PACKAGES="${PACKAGES:-}"; \
        echo "Existing PACKAGES: ${EXISTING_PACKAGES:-<not set - gen-vm will use defaults>}"; \
        if [ -f /build/packages.txt ]; then \
            echo "Reading packages from /build/packages.txt..."; \
            ADDITIONAL_PACKAGES=$(sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" /build/packages.txt | grep -v '^#' | grep -v '^$' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || echo ""); \
            echo "Additional packages: ${ADDITIONAL_PACKAGES}"; \
            if [ -n "${ADDITIONAL_PACKAGES}" ]; then \
                if [ -n "${EXISTING_PACKAGES}" ]; then \
                    export PACKAGES="${EXISTING_PACKAGES} ${ADDITIONAL_PACKAGES}"; \
                    echo "Appending additional packages to existing PACKAGES"; \
                else \
                    echo "PACKAGES not set - checking gen-vm for default packages file..."; \
                    GENVM_DEFAULT_PACKAGES_FILE=$(grep -E "^PACKAGES=" ./gen-vm 2>/dev/null | head -1 | sed 's/.*:-\([^}]*\)}.*/\1/' || echo ""); \
                    if [ -z "${GENVM_DEFAULT_PACKAGES_FILE}" ]; then \
                        GENVM_DEFAULT_PACKAGES_FILE="../packages.d/packages-default"; \
                    fi; \
                    echo "Looking for default packages file at: ${GENVM_DEFAULT_PACKAGES_FILE}"; \
                    if [ -f "${GENVM_DEFAULT_PACKAGES_FILE}" ]; then \
                        echo "Found gen-vm default packages file: ${GENVM_DEFAULT_PACKAGES_FILE}"; \
                        COMBINED_PACKAGES_FILE="/tmp/packages-combined"; \
                        echo "Creating combined packages file: ${COMBINED_PACKAGES_FILE}"; \
                        cat "${GENVM_DEFAULT_PACKAGES_FILE}" > "${COMBINED_PACKAGES_FILE}"; \
                        echo "" >> "${COMBINED_PACKAGES_FILE}"; \
                        echo "# Additional packages from packages.txt" >> "${COMBINED_PACKAGES_FILE}"; \
                        for PKG in ${ADDITIONAL_PACKAGES}; do \
                            echo "  - ${PKG}" >> "${COMBINED_PACKAGES_FILE}"; \
                        done; \
                        echo "Combined packages file created with defaults + additional packages"; \
                        export PACKAGES="${COMBINED_PACKAGES_FILE}"; \
                    else \
                        echo "Default packages file not found: ${GENVM_DEFAULT_PACKAGES_FILE}"; \
                        echo "Creating packages file with additional packages only..."; \
                        COMBINED_PACKAGES_FILE="/tmp/packages-combined"; \
                        echo "# Packages from packages.txt" > "${COMBINED_PACKAGES_FILE}"; \
                        for PKG in ${ADDITIONAL_PACKAGES}; do \
                            echo "  - ${PKG}" >> "${COMBINED_PACKAGES_FILE}"; \
                        done; \
                        export PACKAGES="${COMBINED_PACKAGES_FILE}"; \
                    fi; \
                fi; \
            fi; \
        else \
            echo "Warning: /build/packages.txt not found, skipping additional packages"; \
        fi; \
        echo "Environment variables:"; \
        echo "  QEMU_PATH=${QEMU_PATH}"; \
        echo "  VM_NAME=${VM_NAME}"; \
        echo "  USERNAME=${USERNAME}"; \
        echo "  IMAGES=${IMAGES}"; \
        echo "  RELEASE=${RELEASE}"; \
        echo "  ARCH=${ARCH}"; \
        echo "  KVM=${KVM} (disabled for Docker build)"; \
        echo "  NO_BACKING=${NO_BACKING} (disabled for Docker build)"; \
        echo "  PACKAGES=${PACKAGES}"; \
        echo "Running gen-vm (KVM disabled, no backing file)..."; \
        ./gen-vm || (echo "gen-vm failed with exit code $?" && exit 1); \
        if [ -f "${IMAGES}/${FINAL_VM_NAME}.qcow2" ]; then \
            echo "Copying VM image to /output/..."; \
            cp "${IMAGES}/${FINAL_VM_NAME}.qcow2" /output/ && \
            echo "Copying SSH keys to /output/..."; \
            cp /root/.ssh/id_rsa /output/id_rsa 2>/dev/null || echo "Warning: SSH private key not found"; \
            cp /root/.ssh/id_rsa.pub /output/id_rsa.pub 2>/dev/null || echo "Warning: SSH public key not found"; \
            echo "VM image created successfully: /output/${FINAL_VM_NAME}.qcow2"; \
            echo "VM image info:"; \
            /opt/qemu/bin/qemu-img info "/output/${FINAL_VM_NAME}.qcow2" || true; \
            echo "Creating vm-info.json..."; \
            QEMU_COMMIT_INFO=$(cat /build/qemu-commit.txt 2>/dev/null || echo "unknown"); \
            LIBVFIO_USER_COMMIT_INFO=$(cat /build/libvfio-user-commit.txt 2>/dev/null || echo "unknown"); \
            QEMU_MINIMAL_COMMIT_INFO=$(cat /build/qemu-minimal-commit.txt 2>/dev/null || echo "unknown"); \
            IMAGE_SIZE=$(stat -c%s "/output/${FINAL_VM_NAME}.qcow2" 2>/dev/null || echo "0"); \
            IMAGE_FORMAT=$(/opt/qemu/bin/qemu-img info "/output/${FINAL_VM_NAME}.qcow2" 2>/dev/null | grep -i "file format" | cut -d: -f2 | xargs || echo "qcow2"); \
            BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ); \
            printf 'import json\nimport sys\nimport os\n\n# Parse KVM setting: "false" or empty means disabled\nkvm_val = os.environ.get("KVM", "false").lower()\nkvm_enabled = kvm_val == "true"\n\n# Parse NO_BACKING setting: "true" means no backing file (backing_file=False)\nno_backing_val = os.environ.get("NO_BACKING", "false").lower()\nbacking_file = no_backing_val != "true"\n\nvm_info = {\n    "vm_name": os.environ["FINAL_VM_NAME"],\n    "username": os.environ["FINAL_USERNAME"],\n    "password": os.environ["FINAL_PASSWORD"],\n    "image_path": f"/output/{os.environ[\047FINAL_VM_NAME\047]}.qcow2",\n    "image_format": os.environ["IMAGE_FORMAT"],\n    "image_size_bytes": int(os.environ["IMAGE_SIZE"]),\n    "release": os.environ["FINAL_RELEASE"],\n    "architecture": os.environ["FINAL_ARCH"],\n    "qemu_path": "/opt/qemu/bin/",\n    "kvm_enabled": kvm_enabled,\n    "backing_file": backing_file,\n    "ssh_keys": {\n        "private_key_path": "/output/id_rsa",\n        "public_key_path": "/output/id_rsa.pub"\n    },\n    "build_info": {\n        "qemu_commit": os.environ["QEMU_COMMIT_INFO"],\n        "libvfio_user_commit": os.environ["LIBVFIO_USER_COMMIT_INFO"],\n        "qemu_minimal_commit": os.environ["QEMU_MINIMAL_COMMIT_INFO"],\n        "build_timestamp": os.environ["BUILD_TIMESTAMP"]\n    }\n}\n\njson.dump(vm_info, sys.stdout, indent=2)\n' > /tmp/create_vm_info.py && \
            FINAL_VM_NAME="${FINAL_VM_NAME}" \
            FINAL_USERNAME="${FINAL_USERNAME}" \
            FINAL_PASSWORD="${FINAL_PASSWORD}" \
            IMAGE_FORMAT="${IMAGE_FORMAT}" \
            IMAGE_SIZE="${IMAGE_SIZE}" \
            FINAL_RELEASE="${FINAL_RELEASE}" \
            FINAL_ARCH="${FINAL_ARCH}" \
            QEMU_COMMIT_INFO="${QEMU_COMMIT_INFO}" \
            LIBVFIO_USER_COMMIT_INFO="${LIBVFIO_USER_COMMIT_INFO}" \
            QEMU_MINIMAL_COMMIT_INFO="${QEMU_MINIMAL_COMMIT_INFO}" \
            BUILD_TIMESTAMP="${BUILD_TIMESTAMP}" \
            KVM="${KVM}" \
            NO_BACKING="${NO_BACKING}" \
            python3 /tmp/create_vm_info.py > /output/vm-info.json && \
            rm -f /tmp/create_vm_info.py && \
            echo "vm-info.json created at /output/vm-info.json"; \
            cat /output/vm-info.json || true; \
            ls -lh /output/ || true; \
        else \
            echo "Error: VM image was not created at ${IMAGES}/${FINAL_VM_NAME}.qcow2"; \
            echo "Contents of ${IMAGES}/:"; \
            ls -la "${IMAGES}/" || true; \
            exit 1; \
        fi; \
        rm -rf "${QEMU_MINIMAL_PATH}"; \
    else \
        echo "QEMU_MINIMAL_REPO not provided, skipping VM build"; \
    fi

# Copy scripts
COPY entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

# Set default environment variables
# Note: VM_NAME defaults to ${USERNAME}-ci-vm if not specified
# Note: PASSWORD should be provided at runtime via environment variable
#       (defaults to 'changeme' in entrypoint if not set)
# Note: VM image is built during Dockerfile build if QEMU_MINIMAL_REPO
#       build arg is provided, otherwise can be mounted at runtime
ENV USERNAME=batesste
ENV QEMU_PATH=/opt/qemu/bin/
ENV PATH=/opt/qemu/bin:${PATH}
ENV SSH_PORT=2222
ENV VCPUS=2
ENV VMEM=4096

# Set entrypoint
ENTRYPOINT ["/build/entrypoint.sh"]
