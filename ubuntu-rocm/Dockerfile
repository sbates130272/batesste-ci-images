FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ROCm version to install (default: latest)
ARG ROCM_VERSION=latest
ENV ROCM_VERSION=${ROCM_VERSION}
ENV UBUNTU_CODENAME=noble

# Cache-busting arg (can be set to force rebuild when Dockerfile logic
# changes)
ARG CACHE_BUST=

# Install prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    python3-setuptools \
    python3-wheel \
    libstdc++-14-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy rocm-latest script
COPY rocm-latest /usr/local/bin/rocm-latest
RUN chmod +x /usr/local/bin/rocm-latest

# Detect latest ROCm version if ROCM_VERSION is "latest"
RUN set -eux; \
    if [ "${ROCM_VERSION}" = "latest" ]; then \
        DETECTED_ROCM=$(QUIET=true ONLY_ONE=ROCM \
            /usr/local/bin/rocm-latest); \
        DETECTED_AMDGPU=$(QUIET=true ONLY_ONE=AMDGPU \
            /usr/local/bin/rocm-latest); \
        echo "${DETECTED_ROCM}" > /tmp/rocm_version.txt; \
        echo "${DETECTED_AMDGPU}" > /tmp/amdgpu_version.txt; \
        echo "Detected ROCm version: ${DETECTED_ROCM}"; \
        echo "Detected AMDGPU version: ${DETECTED_AMDGPU}"; \
    else \
        echo "${ROCM_VERSION}" > /tmp/rocm_version.txt; \
        DETECTED_AMDGPU=$(QUIET=true ONLY_ONE=AMDGPU \
            /usr/local/bin/rocm-latest); \
        echo "${DETECTED_AMDGPU}" > /tmp/amdgpu_version.txt; \
        echo "Using specified ROCm version: ${ROCM_VERSION}"; \
        echo "Detected AMDGPU version: ${DETECTED_AMDGPU}"; \
    fi

RUN apt update && \
    apt install -y \
        curl \
        gpg

# Retrieve ROCm GPG key
RUN curl https://repo.radeon.com/rocm/rocm.gpg.key | \
    gpg --dearmor >> /etc/apt/keyrings/rocm.gpg

# Manually setup ROCm Package Repos
RUN cat <<EOF > /etc/apt/sources.list.d/rocm.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${UBUNTU_CODENAME} main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${ROCM_VERSION}/ubuntu ${UBUNTU_CODENAME} main
EOF

RUN cat <<EOF > /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

# Development Dependencies
RUN apt update && \
    apt install -y \
        clang \
        cmake \
        doxygen \
        gdb \
        git \
        hip-dev \
        libboost-program-options-dev \
        libmount-dev \
        librocthrust-dev \
        libssl-dev \
        llvm-dev \
        rocm-llvm-dev

# Configure system linker for ROCm
RUN cat <<EOF > /etc/ld.so.conf.d/rocm.conf
/opt/rocm/lib
/opt/rocm/lib64
EOF
RUN ldconfig

# Update PCIe ID tables (for new GPU support)
RUN apt-get update && apt-get install -y --no-install-recommends \
    pciutils \
    && update-pciids \
    && rm -rf /var/lib/apt/lists/*

# Set up environment variables
ENV PATH=/opt/rocm/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:${LD_LIBRARY_PATH:-}

# Set working directory
WORKDIR /build

CMD ["/bin/bash"]
