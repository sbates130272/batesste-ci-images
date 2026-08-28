FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    ninja-build \
    pkg-config \
    git \
    meson \
    libglib2.0-dev \
    libjson-c-dev \
    libcmocka-dev \
    libibverbs-dev \
    librdmacm-dev \
    && rm -rf /var/lib/apt/lists/*

# Install AMD root CA if present in build context (ZScaler proxy on AMD network).
# No-op in CI where the file is absent.
# hadolint ignore=DL3003
RUN --mount=type=bind,source=.,target=/ctx \
    if [ -f /ctx/common/amd-root-ca.crt ]; then \
        cp /ctx/common/amd-root-ca.crt \
            /usr/local/share/ca-certificates/amd-root-ca.crt && \
        update-ca-certificates; \
    fi

# Accept libvfio-user and rocm-ernic commit SHAs as build arguments
ARG LIBVFIO_USER_REPO=https://gitlab.com/qemu-project/libvfio-user.git
ARG LIBVFIO_USER_COMMIT=082925c65d98021af5c0f36f60a98e0bb6ddb329
ARG ROCM_ERNIC_REPO=https://github.com/ROCm/rocm-ernic.git
ARG ROCM_ERNIC_COMMIT=e65d71539e62403f278c36055c7fe1e97d86202a

WORKDIR /build

# Clone and build libvfio-user (same SHA as ubuntu-qemu-libvfio-user)
RUN git clone --filter=blob:none \
    "${LIBVFIO_USER_REPO}" \
    /build/libvfio-user && \
    cd /build/libvfio-user && \
    git checkout "${LIBVFIO_USER_COMMIT}" && \
    git rev-parse HEAD \
        > /build/libvfio-user-commit.txt && \
    meson setup build --prefix=/usr/local && \
    ninja -C build && \
    ninja -C build install && \
    ldconfig && \
    rm -rf /build/libvfio-user

# Clone rocm-ernic at the pinned SHA
RUN git clone --filter=blob:none \
    "${ROCM_ERNIC_REPO}" \
    /build/rocm-ernic && \
    cd /build/rocm-ernic && \
    git checkout "${ROCM_ERNIC_COMMIT}" && \
    git rev-parse HEAD \
        > /build/rocm-ernic-commit.txt

# Build rocm-ernic
RUN cmake \
    -B /build/rocm-ernic/build \
    -G Ninja \
    -S /build/rocm-ernic \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DERNIC_WERROR=OFF && \
    cmake --build /build/rocm-ernic/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-ernic/build && \
    ldconfig

# Save installed binary path and commit info
RUN cp /build/rocm-ernic-commit.txt /usr/local/share/rocm-ernic-commit.txt && \
    cp /build/libvfio-user-commit.txt \
        /usr/local/share/libvfio-user-commit.txt && \
    rm -rf /build/rocm-ernic

ENV PATH=/usr/local/bin:${PATH}

CMD ["rocm-ernic", "--help"]
