FROM ubuntu:24.04

# Cache-busting arg (can be set to force rebuild when Dockerfile logic changes)
ARG CACHE_BUST=

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Disable unattended-upgrades to prevent apt lock conflicts
RUN apt-get update && \
    apt-get remove -y --purge \
      unattended-upgrades || true && \
    echo 'APT::Periodic::Update-Package-Lists "0";' \
      > /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::Unattended-Upgrade "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades && \
    rm -rf /var/lib/apt/lists/*

# Install kernel build dependencies and headers
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
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
    linux-headers-generic \
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

# Set working directory and create output directory
WORKDIR /build
RUN mkdir -p /output

CMD ["/bin/bash"]
