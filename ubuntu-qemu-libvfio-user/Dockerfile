# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Disable unattended-upgrades to prevent apt lock conflicts
RUN apt-get update && \
    apt-get remove -y --purge \
      unattended-upgrades || true && \
    echo 'APT::Periodic::Update-Package-Lists "0";' \
      > /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::Unattended-Upgrade "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades && \
    rm -rf /var/lib/apt/lists/*

# Install build dependencies for QEMU and libvfio-user
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    git \
    jq \
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

# Accept QEMU and libvfio-user tags or commit SHAs
ARG QEMU_COMMIT=v10.2.2
ARG LIBVFIO_USER_COMMIT=082925c65d98021af5c0f36f60a98e0bb6ddb329

# Accept qemu-minimal configuration as build arguments
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=noble
ARG ARCH=amd64
ARG CACHE_BUST=

WORKDIR /build

# Clone and build libvfio-user (treeless clone for speed)
RUN git clone --filter=blob:none \
    https://gitlab.com/qemu-project/libvfio-user.git \
    /build/libvfio-user && \
    cd /build/libvfio-user && \
    git checkout ${LIBVFIO_USER_COMMIT} && \
    git rev-parse HEAD \
        > /build/libvfio-user-commit.txt && \
    meson setup build && \
    ninja -C build && \
    ninja -C build install && \
    rm -rf /build/libvfio-user

# Clone QEMU: shallow clone for tags, treeless for SHAs
RUN if echo "${QEMU_COMMIT}" | \
        grep -qE '^[0-9a-f]{7,40}$'; then \
        git clone --filter=blob:none \
            https://gitlab.com/qemu-project/qemu.git \
            /build/qemu && \
        cd /build/qemu && \
        git checkout ${QEMU_COMMIT}; \
    else \
        git clone --depth 1 \
            --branch ${QEMU_COMMIT} \
            https://gitlab.com/qemu-project/qemu.git \
            /build/qemu; \
    fi && \
    cd /build/qemu && \
    git rev-parse HEAD > /build/qemu-commit.txt

# Build QEMU with slirp networking support
WORKDIR /build/qemu
RUN ./configure --target-list=x86_64-softmmu \
                --enable-slirp \
                --prefix=/opt/qemu && \
    make -j$(nproc) && \
    make install && \
    rm -rf /build/qemu

# Install cloud-init utilities for VM creation
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    cloud-image-utils \
    qemu-utils \
    wget \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Create output directory and copy packages file
RUN mkdir -p /output
COPY packages.txt /build/packages.txt

# Generate SSH keys for VM access
RUN mkdir -p /root/.ssh && \
    ssh-keygen -t rsa -b 4096 \
        -f /root/.ssh/id_rsa -N "" -q

# Clone qemu-minimal if repo is provided (separate
# layer so it is cached independently of VM build)
WORKDIR /build
RUN set -eux; \
    if [ -z "${QEMU_MINIMAL_REPO}" ]; then \
        echo "QEMU_MINIMAL_REPO not set, skipping"; \
    else \
        git clone "${QEMU_MINIMAL_REPO}" \
            /build/qemu-minimal && \
        cd /build/qemu-minimal && \
        if [ -n "${QEMU_MINIMAL_COMMIT}" ]; then \
            git checkout \
                "${QEMU_MINIMAL_COMMIT}"; \
        fi && \
        git rev-parse HEAD \
            > /build/qemu-minimal-commit.txt; \
    fi

# Build VM image and generate metadata.
# --mount binds cloud-image-cache/ from the build
# context; pre-downloaded images are placed where
# gen-vm looks so it can skip the download.
# hadolint ignore=DL3059
RUN --mount=type=bind,source=cloud-image-cache,target=/tmp/cloud-cache \
    set -eux; \
    if [ ! -d /build/qemu-minimal ]; then \
        echo "No qemu-minimal, skipping VM build"; \
    else \
        QM=/build/qemu-minimal; \
        FINAL_VM_NAME="${VM_NAME:-${USERNAME}-ci-vm}"; \
        FINAL_USERNAME="${USERNAME:-batesste}"; \
        FINAL_PASSWORD="${PASSWORD:-changeme}"; \
        FINAL_RELEASE="${RELEASE:-noble}"; \
        FINAL_ARCH="${ARCH:-amd64}"; \
        KERNEL_VERSION=$(uname -r); \
        echo "=== VM Build Configuration ==="; \
        echo "Cache-bust: ${CACHE_BUST:-none}"; \
        echo "QEMU_MINIMAL_REPO: ${QEMU_MINIMAL_REPO}"; \
        echo "QEMU_MINIMAL_COMMIT: ${QEMU_MINIMAL_COMMIT:-HEAD}"; \
        echo "VM_NAME: ${FINAL_VM_NAME}"; \
        echo "USERNAME: ${FINAL_USERNAME}"; \
        echo "RELEASE: ${FINAL_RELEASE}"; \
        echo "ARCH: ${FINAL_ARCH}"; \
        echo "Kernel version: ${KERNEL_VERSION}"; \
        mkdir -p "${QM}/images"; \
        cp /tmp/cloud-cache/*.img \
            "${QM}/images/" 2>/dev/null || true; \
        [ -d "${QM}/qemu" ] || \
            { echo "Error: qemu directory not found!"; \
              ls -la "${QM}/"; exit 1; }; \
        [ -f "${QM}/qemu/gen-vm" ] || \
            { echo "Error: gen-vm script not found!"; \
              ls -la "${QM}/qemu/"; exit 1; }; \
        cd "${QM}/qemu"; \
        export QEMU_PATH=/opt/qemu/bin/ \
               VM_NAME="${FINAL_VM_NAME}" \
               USERNAME="${FINAL_USERNAME}" \
               PASS="${FINAL_PASSWORD}" \
               IMAGES="${QM}/images" \
               RELEASE="${FINAL_RELEASE}" \
               ARCH="${FINAL_ARCH}" \
               KVM=false \
               NO_BACKING=true; \
        if [ -f /build/packages.txt ]; then \
            ADDITIONAL_PACKAGES=$(sed \
                "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" \
                /build/packages.txt | \
                grep -v '^#' | grep -v '^$' | \
                tr '\n' ' ' | \
                sed 's/[[:space:]]*$//'); \
            if [ -n "${ADDITIONAL_PACKAGES}" ]; then \
                if [ -n "${PACKAGES:-}" ]; then \
                    export PACKAGES="${PACKAGES} ${ADDITIONAL_PACKAGES}"; \
                else \
                    GENVM_DEFAULT_PACKAGES_FILE=$( \
                        grep -E "^PACKAGES=" \
                            ./gen-vm 2>/dev/null | \
                        head -1 | \
                        sed 's/.*:-\([^}]*\)}.*/\1/' \
                        || echo \
                        "../packages.d/packages-default" \
                    ); \
                    COMBINED="/tmp/packages-combined"; \
                    if [ -f "${GENVM_DEFAULT_PACKAGES_FILE}" ]; then \
                        cat "${GENVM_DEFAULT_PACKAGES_FILE}" \
                            > "${COMBINED}"; \
                        echo "" >> "${COMBINED}"; \
                        echo "# Additional packages from packages.txt" \
                            >> "${COMBINED}"; \
                    else \
                        echo "# Packages from packages.txt" \
                            > "${COMBINED}"; \
                    fi; \
                    for PKG in ${ADDITIONAL_PACKAGES}; do \
                        echo "  - ${PKG}" \
                            >> "${COMBINED}"; \
                    done; \
                    export PACKAGES="${COMBINED}"; \
                fi; \
            fi; \
        fi; \
        echo "Running gen-vm (KVM disabled, no backing file)..."; \
        ./gen-vm || \
            { echo "gen-vm failed with exit code $?"; \
              exit 1; }; \
        [ -f "${IMAGES}/${FINAL_VM_NAME}.qcow2" ] || \
            { echo "Error: VM image not created!"; \
              ls -la "${IMAGES}/"; exit 1; }; \
        cp "${IMAGES}/${FINAL_VM_NAME}.qcow2" \
            /output/ && \
        cp /root/.ssh/id_rsa /output/id_rsa \
            2>/dev/null || true; \
        cp /root/.ssh/id_rsa.pub /output/id_rsa.pub \
            2>/dev/null || true; \
        QEMU_COMMIT_INFO=$(cat \
            /build/qemu-commit.txt 2>/dev/null \
            || echo "unknown"); \
        LIBVFIO_USER_COMMIT_INFO=$(cat \
            /build/libvfio-user-commit.txt \
            2>/dev/null || echo "unknown"); \
        QEMU_MINIMAL_COMMIT_INFO=$(cat \
            /build/qemu-minimal-commit.txt \
            2>/dev/null || echo "unknown"); \
        IMAGE_SIZE=$(stat -c%s \
            "/output/${FINAL_VM_NAME}.qcow2" \
            2>/dev/null || echo "0"); \
        IMAGE_FORMAT=$(/opt/qemu/bin/qemu-img info \
            "/output/${FINAL_VM_NAME}.qcow2" \
            2>/dev/null | \
            grep -i "file format" | \
            cut -d: -f2 | xargs || echo "qcow2"); \
        BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ); \
        printf 'import json\nimport sys\nimport os\n\nkvm_val = os.environ.get("KVM", "false").lower()\nkvm_enabled = kvm_val == "true"\nno_backing_val = os.environ.get("NO_BACKING", "false").lower()\nbacking_file = no_backing_val != "true"\n\nvm_info = {\n    "vm_name": os.environ["FINAL_VM_NAME"],\n    "username": os.environ["FINAL_USERNAME"],\n    "password": os.environ["FINAL_PASSWORD"],\n    "image_path": f"/output/{os.environ[\047FINAL_VM_NAME\047]}.qcow2",\n    "image_format": os.environ["IMAGE_FORMAT"],\n    "image_size_bytes": int(os.environ["IMAGE_SIZE"]),\n    "release": os.environ["FINAL_RELEASE"],\n    "architecture": os.environ["FINAL_ARCH"],\n    "qemu_path": "/opt/qemu/bin/",\n    "kvm_enabled": kvm_enabled,\n    "backing_file": backing_file,\n    "ssh_keys": {\n        "private_key_path": "/output/id_rsa",\n        "public_key_path": "/output/id_rsa.pub"\n    },\n    "build_info": {\n        "qemu_commit": os.environ["QEMU_COMMIT_INFO"],\n        "libvfio_user_commit": os.environ["LIBVFIO_USER_COMMIT_INFO"],\n        "qemu_minimal_commit": os.environ["QEMU_MINIMAL_COMMIT_INFO"],\n        "build_timestamp": os.environ["BUILD_TIMESTAMP"]\n    }\n}\n\njson.dump(vm_info, sys.stdout, indent=2)\n' > /tmp/create_vm_info.py && \
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
        python3 /tmp/create_vm_info.py \
            > /output/vm-info.json && \
        rm -f /tmp/create_vm_info.py && \
        rm -rf "${QM}"; \
    fi

# Copy scripts
COPY entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

# Set default environment variables
ENV USERNAME=batesste
ENV QEMU_PATH=/opt/qemu/bin/
ENV PATH=/opt/qemu/bin:${PATH}
ENV SSH_PORT=2222
ENV VCPUS=2
ENV VMEM=4096

ENTRYPOINT ["/build/entrypoint.sh"]
