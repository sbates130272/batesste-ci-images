ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# Cache-busting arg (can be set to force rebuild when Dockerfile logic changes)
ARG CACHE_BUST=

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install kernel build dependencies and headers
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    libncurses-dev \
    libssl-dev \
    libelf-dev \
    bc \
    bison \
    flex \
    dwarves \
    rsync \
    kmod \
    cpio \
    linux-headers-generic

# Set working directory and create output directory
WORKDIR /build
RUN mkdir -p /output

CMD ["/bin/bash"]
