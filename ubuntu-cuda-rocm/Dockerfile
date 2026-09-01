FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV UBUNTU_CODENAME=noble

ARG CUDA_VERSION=13-3
ARG ROCM_VERSION=7.14
# ROCM_STREAM: 'therock' (repo.amd.com, ROCm 7.13+) or 'legacy' (repo.radeon.com, ROCm ≤7.2)
ARG ROCM_STREAM=therock
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

# Install AMD root CA if present in build context (ZScaler proxy on AMD network).
# No-op in CI where the file is absent.
# hadolint ignore=DL3003
RUN --mount=type=bind,source=.,target=/ctx \
    if [ -f /ctx/common/amd-root-ca.crt ]; then \
        cp /ctx/common/amd-root-ca.crt \
            /usr/local/share/ca-certificates/amd-root-ca.crt && \
        update-ca-certificates; \
    fi

COPY ubuntu-cuda-rocm/cuda-latest ubuntu-cuda-rocm/rocm-latest /usr/local/bin/
RUN chmod +x /usr/local/bin/cuda-latest /usr/local/bin/rocm-latest

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/cache_bust.txt

# Resolve CUDA version for traceability
RUN set -eux; \
    if [ "${CUDA_VERSION}" = "latest" ]; then \
        DETECTED_CUDA=$(QUIET=true /usr/local/bin/cuda-latest); \
    else \
        DETECTED_CUDA="${CUDA_VERSION}"; \
    fi; \
    echo "${DETECTED_CUDA}" > /etc/cuda-version; \
    echo "${ROCM_VERSION}" > /etc/rocm-version; \
    echo "${ROCM_STREAM}" > /etc/rocm-stream

# Increase apt retries and timeouts for large package downloads through proxy
RUN printf 'Acquire::Retries "10";\nAcquire::http::Timeout "600";\nAcquire::https::Timeout "600";\n' \
    > /etc/apt/apt.conf.d/99-proxy-retries

# NVIDIA CUDA repository (ubuntu2404 / noble)
RUN wget -q -O /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && apt-get update

# AMD ROCm repository — therock stream (repo.amd.com) or legacy (repo.radeon.com)
RUN mkdir -p /etc/apt/keyrings && \
    if [ "${ROCM_STREAM}" = "therock" ]; then \
        curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg \
            | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg && \
        printf 'Types: deb\nURIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2404\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/amdrocm.gpg\n' \
            > /etc/apt/sources.list.d/rocm.sources; \
    else \
        curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg && \
        printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/%s %s main\n' \
            "${ROCM_VERSION}" "${UBUNTU_CODENAME}" \
            > /etc/apt/sources.list.d/rocm.list && \
        printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
            > /etc/apt/preferences.d/rocm-pin-600; \
    fi

# CUDA toolkit (dev only; no drivers)
RUN set -eux; \
    CUDA_PKG_VER=$(cat /etc/cuda-version); \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "cuda-toolkit-${CUDA_PKG_VER}"; \
    rm -rf /var/lib/apt/lists/*

# ROCm development stack (dev only; no drivers)
# therock stream meta package is 'amdrocm'; legacy stream is 'rocm' (or versioned variant)
RUN set -eux; \
    apt-get update; \
    ROCM_STREAM=$(cat /etc/rocm-stream); \
    if [ "${ROCM_STREAM}" = "therock" ]; then \
        # The therock 'amdrocm' meta ships hipcc and the HIP runtime but not
        # the HIP headers, so pull the runtime dev package explicitly.
        set -- amdrocm amdrocm-runtime-dev; \
    else \
        set -- rocm; \
    fi; \
    apt-get install -y --no-install-recommends \
        clang \
        doxygen \
        gdb \
        libboost-program-options-dev \
        libmount-dev \
        libstdc++-14-dev \
        "$@" \
    && update-pciids \
    && rm -rf /var/lib/apt/lists/*

# Resolve the installed toolkit roots. The therock stream nests everything
# under /opt/rocm/core-<ver> rather than /opt/rocm, so the root must be probed
# rather than assumed. Recorded for downstream images to consume.
RUN set -eux; \
    if [ -f /opt/rocm/include/hip/hip_runtime.h ]; then \
        ROCM_ROOT=/opt/rocm; \
    else \
        ROCM_ROOT=$(find /opt/rocm -maxdepth 1 -mindepth 1 -type d -name 'core-*' \
            | sort -V | tail -n 1); \
    fi; \
    test -n "${ROCM_ROOT}"; \
    echo "${ROCM_ROOT}" > /etc/rocm-path; \
    if [ -d /usr/local/cuda ]; then \
        CUDA_ROOT=/usr/local/cuda; \
    else \
        CUDA_ROOT=$(find /usr/local -maxdepth 1 -mindepth 1 -type d -name 'cuda-*' \
            | sort -V | tail -n 1); \
    fi; \
    test -n "${CUDA_ROOT}"; \
    echo "${CUDA_ROOT}" > /etc/cuda-path

# Linker configuration
RUN set -eux; \
    ROCM_ROOT=$(cat /etc/rocm-path); \
    CUDA_ROOT=$(cat /etc/cuda-path); \
    printf '%s/lib\n%s/lib64\n' "${ROCM_ROOT}" "${ROCM_ROOT}" \
        > /etc/ld.so.conf.d/rocm.conf; \
    printf '%s/lib64\n' "${CUDA_ROOT}" > /etc/ld.so.conf.d/cuda.conf; \
    ldconfig

# Per-stack environment (avoid mixing LD_LIBRARY_PATH in Dockerfile ENV)
RUN cat <<'EOF' > /etc/profile.d/cuda.sh
# NVIDIA CUDA toolkit environment
if [ -r /etc/cuda-path ]; then
    CUDA_HOME="$(cat /etc/cuda-path)"
    export CUDA_HOME
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
fi
EOF

RUN cat <<'EOF' > /etc/profile.d/rocm.sh
# AMD ROCm / HIP development environment
if [ -r /etc/rocm-path ]; then
    ROCM_PATH="$(cat /etc/rocm-path)"
    export ROCM_PATH
    export PATH="${ROCM_PATH}/bin:${PATH}"
    export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${ROCM_PATH}/lib64:${LD_LIBRARY_PATH:-}"
fi
EOF

WORKDIR /build

CMD ["/bin/bash"]
