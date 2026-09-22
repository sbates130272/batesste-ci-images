# libvfio-user is already built and installed under /usr/local by the base
# image, which pins the same SHA this image used to build for itself.
ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-libvfio-user:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies beyond those in the base image
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    libibverbs-dev \
    librdmacm-dev

ARG ROCM_ERNIC_REPO=https://github.com/ROCm/rocm-ernic.git
ARG ROCM_ERNIC_COMMIT=0b48aa1d5821a66c4fb5b78f049b1d9a759a6e17

WORKDIR /build

# Clone rocm-ernic at the pinned SHA
RUN git clone --filter=blob:none \
    "${ROCM_ERNIC_REPO}" \
    /build/rocm-ernic && \
    cd /build/rocm-ernic && \
    git checkout "${ROCM_ERNIC_COMMIT}" && \
    git rev-parse HEAD \
        > /build/rocm-ernic-commit.txt

# Build rocm-ernic
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    cmake \
    -B /build/rocm-ernic/build \
    -G Ninja \
    -S /build/rocm-ernic \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DERNIC_WERROR=OFF && \
    cmake --build /build/rocm-ernic/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-ernic/build && \
    ldconfig

# Save installed binary path and commit info
# (libvfio-user-commit.txt is already in place, written by the base image)
#
# s3_rdma_client.c comes along with it. It is the guest half of the s3
# backend -- the client hipObject would be in production -- and upstream
# wrote it to be copied into a VM and built there alone:
#
#     cc -O2 -Wall -Wextra -o s3_rdma_client s3_rdma_client.c -libverbs
#
# Shipping it here rather than fetching it at test time is what keeps the
# client and the server on the same commit: both come out of this image, and
# rocm-ernic-commit.txt names the commit they came from. A client fetched
# separately can disagree with the server about the x-amz-rdma-token layout,
# and the failure that produces is a transfer that goes nowhere.
# scripts/perf-harness.sh builds it in the guest to measure S3 over RDMA.
RUN cp /build/rocm-ernic-commit.txt /usr/local/share/rocm-ernic-commit.txt && \
    install -D -m 0644 /build/rocm-ernic/tests/s3_rdma_client.c \
        /usr/local/share/rocm-ernic/s3_rdma_client.c && \
    rm -rf /build/rocm-ernic

ENV PATH=/usr/local/bin:${PATH}

CMD ["rocm-ernic", "--help"]
