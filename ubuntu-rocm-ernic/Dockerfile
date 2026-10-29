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
ARG ROCM_ERNIC_COMMIT

# The pin(s) above carry no default on purpose -- images.yml is the only place
# a pin is written. See "Why the Dockerfiles have no pin defaults" in the
# README. An undefaulted ARG is empty rather than an error, so this asserts.
RUN : "${ROCM_ERNIC_COMMIT:?set from images.yml by ci-images-tool.py; pass --build-arg ROCM_ERNIC_COMMIT=... for a bare docker build}"

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
#
# ERNIC_BUILD_P4=ON is off in upstream's CMakeLists, and its stated reason --
# "it takes a direct dependency on json-c, which a superproject building
# rocm-ernic should not have to satisfy unasked" -- does not apply here: the
# base image already carries libjson-c-dev, because libvfio-user requires it.
# So the engine costs this image nothing it was not already paying for.
#
# Building it is not the same as running it. The P4 match-action pipeline sits
# between the guest's Ethernet queues and the host backend and is inert until
# the server is started with --p4 or --p4-program; a stack that passes neither
# gets byte-identical behaviour to a build without this flag. What the flag
# buys is that `rocm-ernic --p4-program ...` is available at all, rather than
# needing a rebuild the first time someone wants to load a program.
#
# A program the engine will not run stops the server starting, by upstream's
# design -- a bad program is a startup failure, never a silently inert
# pipeline -- so nothing here can degrade into "P4 looked enabled and did
# nothing".
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    cmake \
    -B /build/rocm-ernic/build \
    -G Ninja \
    -S /build/rocm-ernic \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DERNIC_BUILD_P4=ON \
    -DERNIC_WERROR=OFF && \
    cmake --build /build/rocm-ernic/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-ernic/build && \
    ldconfig

# Prove the engine is actually in the binary, because a cmake option that
# silently did nothing -- renamed upstream, or gated on something else -- would
# leave a server that refuses --p4 at the moment someone needs it, in a stack
# that has already booted a guest. --help lists the flag only when the engine
# is compiled in.
RUN rocm-ernic --help 2>&1 | grep -q -- '--p4-program'

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
#
# src/parse_int.h goes with it. That "built there alone" invocation stopped
# working the moment the client grew `#include "parse_int.h"`: the header is
# header-only and needs nothing but libc, but it lives under src/ rather than
# tests/, so copying only the .c leaves the guest compile dead at
# `fatal error: parse_int.h: No such file or directory`. That is what made the
# ernic perf badge read n/a -- the metric was recorded as a skip on every
# nightly, which looks exactly like a lane nobody runs.
RUN cp /build/rocm-ernic-commit.txt /usr/local/share/rocm-ernic-commit.txt && \
    install -D -m 0644 /build/rocm-ernic/tests/s3_rdma_client.c \
        /usr/local/share/rocm-ernic/s3_rdma_client.c && \
    install -D -m 0644 /build/rocm-ernic/src/parse_int.h \
        /usr/local/share/rocm-ernic/parse_int.h && \
    rm -rf /build/rocm-ernic

ENV PATH=/usr/local/bin:${PATH}

CMD ["rocm-ernic", "--help"]
