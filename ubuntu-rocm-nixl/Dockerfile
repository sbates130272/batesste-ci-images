ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-cuda-rocm:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

ARG NIXL_REPO=https://github.com/ai-dynamo/nixl.git
ARG NIXL_COMMIT=6c352ce2e6396d5f7179e96f5f3bd4eac88b30c4
ARG UCX_REPO=https://github.com/openucx/ucx.git
ARG UCX_COMMIT=42fc490e469b2f824374357c51227512323d5856

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    flex \
    libasio-dev \
    libclang-dev \
    libcpprest-dev \
    libgflags-dev \
    libibverbs-dev \
    libnuma-dev \
    libprotobuf-dev \
    libssl-dev \
    libtool \
    libtomlplusplus-dev \
    libunwind-dev \
    meson \
    protobuf-compiler \
    python3-dev \
    python3-pip \
    rdma-core \
    uuid-dev \
    zlib1g-dev

WORKDIR /build

RUN git init /build/ucx && \
    git -C /build/ucx remote add origin "${UCX_REPO}" && \
    git -C /build/ucx fetch --depth 1 origin "${UCX_COMMIT}" && \
    git -C /build/ucx checkout FETCH_HEAD && \
    git -C /build/ucx rev-parse HEAD > /build/ucx-commit.txt

# Build UCX with ROCm support so its GPU transport can register HIP memory.
# The ROCm root is discovered by the base image because the therock layout is
# versioned and does not always provide /opt/rocm/lib directly.
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    set -eux; \
    ROCM_PATH="$(cat /etc/rocm-path)"; \
    cd /build/ucx; \
    ./autogen.sh; \
    ./contrib/configure-release-mt \
        --prefix=/usr/local \
        --enable-shared \
        --disable-static \
        --disable-doxygen-doc \
        --enable-devel-headers \
        --with-rocm="${ROCM_PATH}" \
        --with-verbs; \
    make -j"$(nproc)"; \
    make install-strip; \
    ldconfig

RUN git init /build/nixl && \
    git -C /build/nixl remote add origin "${NIXL_REPO}" && \
    git -C /build/nixl fetch --depth 1 origin "${NIXL_COMMIT}" && \
    git -C /build/nixl checkout FETCH_HEAD && \
    git -C /build/nixl rev-parse HEAD > /build/nixl-commit.txt

ARG ABSL_REPO=https://github.com/abseil/abseil-cpp.git
ARG ABSL_TAG=lts_2025_08_14
ARG GRPC_REPO=https://github.com/grpc/grpc.git
ARG GRPC_TAG=v1.73.0

# Abseil and gRPC are built from source, and libgrpc++-dev is deliberately absent
# from the apt list above: it is the only package that pulls libabsl-dev, whose
# 20220623 Abseil predates absl_log. NIXL probes the system Abseil unconditionally
# and refuses to fall back to its bundled subproject when it finds a partial one,
# because that would link two Abseil versions into one process. etcd-cpp-apiv3
# needs gRPC, and it is nixlbench's only distributed runtime, so dropping gRPC is
# not an option -- a complete, modern Abseil is. C++20 must match NIXL's own
# cpp_std across all of these, since Abseil's ABI varies with the standard.
RUN set -eux; \
    git clone --depth 1 --branch "${ABSL_TAG}" "${ABSL_REPO}" /build/abseil-cpp; \
    cmake -B /build/abseil-cpp/build \
        -G Ninja \
        -S /build/abseil-cpp \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_CXX_STANDARD=20 \
        -DBUILD_SHARED_LIBS=ON \
        -DABSL_PROPAGATE_CXX_STD=ON \
        -DABSL_ENABLE_INSTALL=ON; \
    cmake --build /build/abseil-cpp/build --parallel "$(nproc)"; \
    cmake --install /build/abseil-cpp/build; \
    ldconfig

RUN set -eux; \
    git clone --depth 1 --branch "${GRPC_TAG}" \
        --recurse-submodules --shallow-submodules "${GRPC_REPO}" /build/grpc; \
    cmake -B /build/grpc/build \
        -G Ninja \
        -S /build/grpc \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_CXX_STANDARD=20 \
        -DBUILD_SHARED_LIBS=ON \
        -DgRPC_INSTALL=ON \
        -DgRPC_BUILD_TESTS=OFF \
        -DgRPC_ABSL_PROVIDER=package \
        -DgRPC_PROTOBUF_PROVIDER=module \
        -DgRPC_SSL_PROVIDER=package \
        -DgRPC_ZLIB_PROVIDER=package \
        -Dabsl_DIR=/usr/local/lib/cmake/absl; \
    cmake --build /build/grpc/build --parallel "$(nproc)"; \
    cmake --install /build/grpc/build; \
    ldconfig

ARG ETCD_REPO=https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git
ARG ETCD_COMMIT=7c6e714f188f9576e25e0350cac4181139eec23e

RUN git init /build/etcd-cpp-apiv3 && \
    git -C /build/etcd-cpp-apiv3 remote add origin "${ETCD_REPO}" && \
    git -C /build/etcd-cpp-apiv3 fetch --depth 1 origin "${ETCD_COMMIT}" && \
    git -C /build/etcd-cpp-apiv3 checkout FETCH_HEAD && \
    sed -i '/^find_dependency(cpprestsdk)$/d' \
        /build/etcd-cpp-apiv3/etcd-cpp-api-config.in.cmake && \
    cmake -B /build/etcd-cpp-apiv3/build \
        -G Ninja \
        -S /build/etcd-cpp-apiv3 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_CXX_STANDARD=20 \
        -DETCD_CMAKE_CXX_STANDARD=20 \
        -DBUILD_ETCD_CORE_ONLY=ON && \
    cmake --build /build/etcd-cpp-apiv3/build --parallel "$(nproc)" && \
    cmake --install /build/etcd-cpp-apiv3/build && \
    ldconfig

# Keep this directory in the image context so local patches can be added
# without changing the source checkout or the build command.
COPY ubuntu-rocm-nixl/patches/nixl /build/patches/nixl

# CUDA_HOME is pointed at nothing on purpose. The base image carries CUDA
# headers and libraries but no nvcc, and NIXL's meson falls back to probing
# /usr/local/cuda, then calls add_languages('CUDA') on whatever it finds --
# which fails without a compiler. Upstream never hits this because its ROCm
# image has no CUDA at all. nixlbench needs no equivalent: use_rocm=true makes
# it skip CUDA outright, since it treats the two as mutually exclusive.
RUN set -eux; \
    if find /build/patches/nixl -type f -name '*.patch' -print -quit | grep -q .; then \
        git -C /build/nixl apply /build/patches/nixl/*.patch; \
    fi; \
    ROCM_PATH="$(cat /etc/rocm-path)"; \
    export CUDA_HOME=/nonexistent CUDA_PATH=/nonexistent; \
    meson setup /build/nixl/build /build/nixl \
        --prefix=/usr/local/nixl \
        --buildtype=release \
        -Dbuild_tests=false \
        -Dbuild_examples=false \
        -Dbuild_docs=false \
        -Dbuild_nixl_ep=false \
        -Drocm_path="${ROCM_PATH}" \
        -Dwheel_variant=rocm \
        -Ducx_path=/usr/local; \
    meson compile -C /build/nixl/build; \
    meson install -C /build/nixl/build

RUN set -eux; \
    meson setup /build/nixl/benchmark/nixlbench/build \
        /build/nixl/benchmark/nixlbench \
        --prefix=/usr/local \
        --buildtype=release \
        -Dnixl_path=/usr/local/nixl \
        -Ducx_path=/usr/local \
        -Drocm_path="$(cat /etc/rocm-path)" \
        -Duse_rocm=true \
        -Dbuild_raw_cli=false; \
    meson compile -C /build/nixl/benchmark/nixlbench/build; \
    meson install -C /build/nixl/benchmark/nixlbench/build; \
    cp /build/ucx-commit.txt /usr/local/share/ucx-commit.txt; \
    cp /build/nixl-commit.txt /usr/local/share/nixl-commit.txt; \
    rm -rf /build/ucx /build/nixl /build/etcd-cpp-apiv3 /build/abseil-cpp \
        /build/grpc /build/patches

ENV PATH=/usr/local/bin:/usr/local/nixl/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/nixl/lib:${LD_LIBRARY_PATH}

CMD ["nixlbench", "--help"]
