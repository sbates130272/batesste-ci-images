# syntax=docker/dockerfile:1-labs

# Selects which VM build stage the final image is assembled
# from: vm-kvm needs the security.insecure entitlement, vm-tcg
# does not.  ci-images-tool.py picks one; see README.md.
ARG VM_STAGE=vm-kvm

# libvfio-user is already built and installed under /usr/local by the base
# image, which pins the same SHA this image used to build for itself.
ARG BASE_IMAGE=docker.io/batesste/batesste-ci-images-ubuntu-libvfio-user:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS base

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for QEMU beyond those in the base image
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    jq \
    python3 \
    python3-venv \
    libpixman-1-dev \
    libslirp-dev

# Accept QEMU tags or commit SHAs
ARG QEMU_REPO=https://gitlab.com/qemu-project/qemu.git
ARG QEMU_COMMIT=v11.1.1

# Accept qemu-minimal configuration as build arguments
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG KVM=true
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=noble
ARG ARCH=amd64
ARG CACHE_BUST=

WORKDIR /build

# Clone QEMU: shallow clone for tags, treeless for SHAs
RUN if echo "${QEMU_COMMIT}" | \
        grep -qE '^[0-9a-f]{7,40}$'; then \
        git clone --filter=blob:none \
            "${QEMU_REPO}" \
            /build/qemu && \
        cd /build/qemu && \
        git checkout "${QEMU_COMMIT}"; \
    else \
        git clone --depth 1 \
            --branch "${QEMU_COMMIT}" \
            "${QEMU_REPO}" \
            /build/qemu; \
    fi && \
    cd /build/qemu && \
    git rev-parse HEAD > /build/qemu-commit.txt

# Build QEMU with slirp networking support
WORKDIR /build/qemu
# --cc/--cxx rather than PATH=/usr/lib/ccache: QEMU's configure records the
# compiler it was handed into the generated ninja files, and a bare "gcc" there
# resolves without ccache when the build re-execs.
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    ./configure --target-list=x86_64-softmmu \
                --enable-slirp \
                --cc="ccache gcc" \
                --cxx="ccache g++" \
                --prefix=/opt/qemu && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /build/qemu

# Install cloud-init utilities for VM creation
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    cloud-image-utils \
    qemu-utils \
    wget \
    openssh-client

# Python packaging tooling. setuptools is no longer implicit on 3.12, and pipx
# installs CLI tools without hand-rolling a venv for each one.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install -y -qq \
    pipx \
    python3-setuptools

# Create output directory and copy packages file
RUN mkdir -p /output
COPY ubuntu-qemu-libvfio-user/packages.txt /build/packages.txt

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

# Install the qemu-tool CLI (gen-vm/run-vm subcommands)
# from the qemu-minimal checkout.  It supersedes the
# deprecated gen-vm/run-vm bash scripts.
RUN set -eux; \
    if [ -d /build/qemu-minimal/qemu ]; then \
        python3 -m venv /opt/qemu-tool; \
        /opt/qemu-tool/bin/pip install --no-cache-dir \
            /build/qemu-minimal/qemu; \
        ln -sf /opt/qemu-tool/bin/qemu-tool \
            /usr/local/bin/qemu-tool; \
        qemu-tool --version; \
    fi

# The VM build script is shared by both VM stages below.
COPY ubuntu-qemu-libvfio-user/build-vm.sh /usr/local/bin/build-vm
RUN chmod +x /usr/local/bin/build-vm

# Build the VM image with KVM acceleration.  --security=insecure
# is what lets the step create and open /dev/kvm, so this stage
# needs "buildx build --allow security.insecure" against a builder
# started with --allow-insecure-entitlement=security.insecure.
# The --mount binds common/cloud-image-cache/ from the build
# context; pre-downloaded images land where gen-vm looks so it
# can skip the download.
FROM base AS vm-kvm
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=noble
ARG ARCH=amd64
ARG CACHE_BUST=
ARG KVM=true
# hadolint ignore=DL3059
RUN --security=insecure \
    --mount=type=bind,source=common/cloud-image-cache,target=/tmp/cloud-cache \
    build-vm

# Same VM build without the insecure entitlement: no /dev/kvm, so
# gen-vm runs under TCG emulation.  Used when the builder cannot
# grant security.insecure.
FROM base AS vm-tcg
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=noble
ARG ARCH=amd64
ARG CACHE_BUST=
ARG KVM=false
# hadolint ignore=DL3059
RUN --mount=type=bind,source=common/cloud-image-cache,target=/tmp/cloud-cache \
    build-vm

# hadolint ignore=DL3006
FROM ${VM_STAGE} AS final

# Copy scripts
COPY ubuntu-qemu-libvfio-user/entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

# Set default environment variables
ENV USERNAME=batesste
ENV QEMU_PATH=/opt/qemu/bin/
ENV PATH=/opt/qemu/bin:${PATH}
ENV SSH_PORT=2222
ENV VCPUS=2
ENV VMEM=4096

# Disable unattended-upgrades to prevent apt lock conflicts.
# Must run after all other apt-get install steps so nothing
# pulls the package back in as a dependency.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get remove -y --purge \
      unattended-upgrades || true && \
    echo 'APT::Periodic::Update-Package-Lists "0";' \
      > /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::Download-Upgradeable-Packages "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::AutocleanInterval "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::Unattended-Upgrade "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades

ENTRYPOINT ["/build/entrypoint.sh"]
