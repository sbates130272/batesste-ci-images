# libvfio-user is already built and installed under /usr/local by the base
# image, which pins the same SHA this image used to build for itself.
ARG BASE_IMAGE=docker.io/batesste/batesste-ci-images-ubuntu-libvfio-user:latest
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
ARG ROCM_ERNIC_COMMIT=e3ef00c2a0c1ba1df95e6cbbe9362c2a1ad1d2fb

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
RUN cp /build/rocm-ernic-commit.txt /usr/local/share/rocm-ernic-commit.txt && \
    rm -rf /build/rocm-ernic

ENV PATH=/usr/local/bin:${PATH}

CMD ["rocm-ernic", "--help"]
