FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV UBUNTU_CODENAME=noble

ARG CUDA_VERSION=latest
ARG ROCM_VERSION=latest
ARG CACHE_BUST=

# Install base build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    gnupg \
    libssl-dev \
    libstdc++-14-dev \
    lsb-release \
    pciutils \
    python3-setuptools \
    python3-wheel \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY cuda-latest rocm-latest /usr/local/bin/
RUN chmod +x /usr/local/bin/cuda-latest /usr/local/bin/rocm-latest

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/cache_bust.txt

# Resolve toolkit versions for traceability and installs
RUN set -eux; \
    if [ "${CUDA_VERSION}" = "latest" ]; then \
        DETECTED_CUDA=$(QUIET=true /usr/local/bin/cuda-latest); \
    else \
        DETECTED_CUDA="${CUDA_VERSION}"; \
    fi; \
    echo "${DETECTED_CUDA}" > /etc/cuda-version; \
    if [ "${ROCM_VERSION}" = "latest" ]; then \
        DETECTED_ROCM=$(QUIET=true ONLY_ONE=ROCM /usr/local/bin/rocm-latest); \
        ROCM_APT_PATH="latest"; \
    else \
        DETECTED_ROCM="${ROCM_VERSION}"; \
        ROCM_APT_PATH="${ROCM_VERSION}"; \
    fi; \
    echo "${DETECTED_ROCM}" > /etc/rocm-version; \
    echo "${ROCM_APT_PATH}" > /etc/rocm-apt-path

# NVIDIA CUDA repository (ubuntu2404 / noble)
RUN wget -q -O /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && apt-get update

# AMD ROCm repository
RUN curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/rocm.gpg

RUN ROCM_APT_PATH=$(cat /etc/rocm-apt-path) && \
    cat <<EOF > /etc/apt/sources.list.d/rocm.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_APT_PATH} ${UBUNTU_CODENAME} main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${ROCM_APT_PATH}/ubuntu ${UBUNTU_CODENAME} main
EOF

RUN cat <<EOF > /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

# CUDA toolkit (dev only; no drivers)
RUN set -eux; \
    CUDA_PKG_VER=$(cat /etc/cuda-version); \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "cuda-toolkit-${CUDA_PKG_VER}"; \
    rm -rf /var/lib/apt/lists/*

# ROCm development stack (dev only; no drivers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    doxygen \
    gdb \
    hip-dev \
    libboost-program-options-dev \
    libmount-dev \
    librocthrust-dev \
    llvm-dev \
    rocm-llvm-dev \
    && update-pciids \
    && rm -rf /var/lib/apt/lists/*

# Linker configuration
RUN cat <<EOF > /etc/ld.so.conf.d/rocm.conf
/opt/rocm/lib
/opt/rocm/lib64
EOF

RUN cat <<EOF > /etc/ld.so.conf.d/cuda.conf
/usr/local/cuda/lib64
EOF

RUN ldconfig

# Per-stack environment (avoid mixing LD_LIBRARY_PATH in Dockerfile ENV)
RUN cat <<'EOF' > /etc/profile.d/cuda.sh
# NVIDIA CUDA toolkit environment
if [ -d /usr/local/cuda ]; then
    export CUDA_HOME=/usr/local/cuda
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
fi
EOF

RUN cat <<'EOF' > /etc/profile.d/rocm.sh
# AMD ROCm / HIP development environment
export ROCM_PATH=/opt/rocm
export PATH="${ROCM_PATH}/bin:${PATH}"
export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${ROCM_PATH}/lib64:${LD_LIBRARY_PATH:-}"
EOF

WORKDIR /build

CMD ["/bin/bash"]
