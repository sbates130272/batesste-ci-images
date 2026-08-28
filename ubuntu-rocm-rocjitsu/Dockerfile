FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    g++-14 \
    gcc-14 \
    git \
    libclang-rt-dev \
    libdrm-dev \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Install AMD root CA if present in common/ (ZScaler proxy on AMD network).
# No-op in CI where the file is absent.
# hadolint ignore=DL3003
RUN --mount=type=bind,source=.,target=/ctx \
    if [ -f /ctx/common/amd-root-ca.crt ]; then \
        cp /ctx/common/amd-root-ca.crt \
            /usr/local/share/ca-certificates/amd-root-ca.crt && \
        update-ca-certificates; \
    fi

ARG ROCJITSU_REPO=https://github.com/ROCm/rocm-systems.git
ARG ROCJITSU_BRANCH=users/agutierr/vfu-pci-device-stage0
ARG ROCJITSU_COMMIT=3429877a85455f446b30684198ec44060938e0ed

WORKDIR /build

RUN git clone --filter=blob:none \
    --branch "${ROCJITSU_BRANCH}" \
    "${ROCJITSU_REPO}" \
    /build/rocm-systems && \
    cd /build/rocm-systems && \
    git checkout "${ROCJITSU_COMMIT}" && \
    git rev-parse HEAD \
        > /build/rocjitsu-commit.txt

RUN cmake \
    -B /build/rocm-systems/build \
    -G Ninja \
    -S /build/rocm-systems/emulation/rocjitsu \
    -DCMAKE_C_COMPILER=gcc-14 \
    -DCMAKE_CXX_COMPILER=g++-14 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_SCAN_FOR_MODULES=OFF \
    "-DCMAKE_CXX_FLAGS=-D_Static_assert=static_assert" \
    "-DCMAKE_SHARED_LINKER_FLAGS=-static-libstdc++" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DFETCHCONTENT_BASE_DIR=/tmp/deps \
    -DROCJITSU_ENABLE_VFIO=ON \
    -DBUILD_TESTING=OFF && \
    cmake --build /build/rocm-systems/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-systems/build && \
    ldconfig

RUN cp /build/rocjitsu-commit.txt \
        /usr/local/share/rocjitsu-commit.txt && \
    rm -rf /build/rocm-systems /tmp/deps

ENV PATH=/usr/local/bin:${PATH}

CMD ["rocjitsu", "--help"]
