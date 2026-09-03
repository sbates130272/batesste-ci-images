FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

ARG CACHE_BUST=

# Increase apt retries and timeouts for large package downloads through proxy
RUN printf 'Acquire::Retries "10";\nAcquire::http::Timeout "600";\nAcquire::https::Timeout "600";\n' \
    > /etc/apt/apt.conf.d/99-proxy-retries

# Hand .deb retention over to BuildKit cache mounts: docker-clean wipes
# /var/cache/apt after every install, which would empty the mount. Every apt
# step in this image and in everything built FROM it must therefore mount
# /var/cache/apt and /var/lib/apt/lists, or the debs land in the layer.
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
      > /etc/apt/apt.conf.d/99keep-cache

# Disable unattended-upgrades to prevent apt lock conflicts
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

# Toolchain shared by every downstream image. Anything here is paid for by
# all of them, so it holds only what at least three images already installed.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    ccache \
    curl \
    git \
    ninja-build \
    pkg-config \
    wget

# Install AMD root CA if present in build context (ZScaler proxy on AMD network).
# No-op in CI where the file is absent.
# hadolint ignore=DL3003
# Mount only common/, not the whole context: BuildKit folds the mounted
# content digest into this step's cache key, so a repo-wide mount makes any
# unrelated edit rebuild every layer below -- including the CUDA/ROCm installs.
RUN --mount=type=bind,source=common,target=/ctx/common \
    if [ -f /ctx/common/amd-root-ca.crt ]; then \
        cp /ctx/common/amd-root-ca.crt \
            /usr/local/share/ca-certificates/amd-root-ca.crt && \
        update-ca-certificates; \
    fi

# Large clones through the proxy stall on the default low-speed cutoff.
RUN git config --global http.postBuffer 524288000 && \
    git config --global http.lowSpeedLimit 0 && \
    git config --global http.lowSpeedTime 0

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/base_cache_bust.txt

WORKDIR /build

CMD ["/bin/bash"]
