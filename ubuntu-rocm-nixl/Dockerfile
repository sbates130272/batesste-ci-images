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
    libgrpc++-dev \
    libibverbs-dev \
    libnuma-dev \
    libprotobuf-dev \
    libtool \
    libtomlplusplus-dev \
    libunwind-dev \
    meson \
    protobuf-compiler \
    protobuf-compiler-grpc \
    python3-dev \
    python3-pip \
    rdma-core \
    uuid-dev

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

ARG ETCD_REPO=https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git
ARG ETCD_COMMIT=7c6e714f188f9576e25e0350cac4181139eec23e

RUN git init /build/etcd-cpp-apiv3 && \
    git -C /build/etcd-cpp-apiv3 remote add origin "${ETCD_REPO}" && \
    git -C /build/etcd-cpp-apiv3 fetch --depth 1 origin "${ETCD_COMMIT}" && \
    git -C /build/etcd-cpp-apiv3 checkout FETCH_HEAD && \
    cmake -B /build/etcd-cpp-apiv3/build \
        -G Ninja \
        -S /build/etcd-cpp-apiv3 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_ETCD_CORE_ONLY=ON && \
    cmake --build /build/etcd-cpp-apiv3/build --parallel "$(nproc)" && \
    cmake --install /build/etcd-cpp-apiv3/build && \
    ldconfig

# Keep this directory in the image context so local patches can be added
# without changing the source checkout or the build command.
COPY ubuntu-rocm-nixl/patches/nixl /build/patches/nixl

RUN set -eux; \
    if find /build/patches/nixl -type f -name '*.patch' -print -quit | grep -q .; then \
        git -C /build/nixl apply /build/patches/nixl/*.patch; \
    fi; \
    ROCM_PATH="$(cat /etc/rocm-path)"; \
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
    rm -rf /build/ucx /build/nixl /build/etcd-cpp-apiv3 /build/patches

ENV PATH=/usr/local/bin:/usr/local/nixl/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/nixl/lib:${LD_LIBRARY_PATH}

CMD ["nixlbench", "--help"]
