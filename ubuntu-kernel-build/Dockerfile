FROM ubuntu:24.04

# Cache-busting arg (can be set to force rebuild when Dockerfile logic changes)
ARG CACHE_BUST=

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install kernel build dependencies and headers
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
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
    linux-headers-generic

# Disable unattended-upgrade
RUN apt-get remove -y unattended-upgrades \
    && rm -rf /var/lib/apt/lists/*

# Set working directory and create output directory
WORKDIR /build
RUN mkdir -p /output

CMD ["/bin/bash"]
