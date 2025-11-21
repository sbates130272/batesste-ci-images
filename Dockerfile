FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for QEMU
RUN apt-get update && apt-get install -y \
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
    && rm -rf /var/lib/apt/lists/*

# Accept QEMU commit hash as build argument (defaults to HEAD)
ARG QEMU_COMMIT=HEAD

# Set working directory
WORKDIR /build

# Clone QEMU repository and checkout specific commit
RUN git clone https://gitlab.com/qemu-project/qemu.git /build/qemu && \
    cd /build/qemu && \
    git checkout ${QEMU_COMMIT} && \
    git rev-parse HEAD > /build/qemu-commit.txt

# Build QEMU with slirp networking support
WORKDIR /build/qemu
RUN ./configure --target-list=x86_64-softmmu \
                --enable-slirp \
                --prefix=/opt/qemu && \
    make -j$(nproc) && \
    make install && \
    cd /build && \
    rm -rf /build/qemu

# Install cloud-init utilities for VM creation
RUN apt-get update && apt-get install -y \
    cloud-image-utils \
    qemu-utils \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Copy build script
COPY build-vm.sh /build/build-vm.sh
RUN chmod +x /build/build-vm.sh

# Set default environment variables
# Note: VM_NAME defaults to ${USERNAME}-ci-vm in build-vm.sh
ENV USERNAME=batesste
ENV PASSWORD=changeme
ENV QEMU_PATH=/opt/qemu/bin/

# Create output directory
RUN mkdir -p /output

# Run build script
CMD ["/build/build-vm.sh"]

