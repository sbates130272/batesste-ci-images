FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install kernel build dependencies
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
    && rm -rf /var/lib/apt/lists/*

# Install kernel headers for building out-of-tree modules
RUN apt-get update && apt-get install -y --no-install-recommends \
    linux-headers-generic \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /build

# Create output directory for built artifacts
RUN mkdir -p /output

# Default to bash shell
CMD ["/bin/bash"]

