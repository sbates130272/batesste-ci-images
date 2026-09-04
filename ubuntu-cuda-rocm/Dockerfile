ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV UBUNTU_CODENAME=noble

ARG CUDA_VERSION=13-3
ARG ROCM_VERSION=7.14
# ROCM_STREAM: 'therock' (repo.amd.com, ROCm 7.13+) or 'legacy' (repo.radeon.com, ROCm ≤7.2)
ARG ROCM_STREAM=therock
ARG CACHE_BUST=

# Install base build dependencies beyond those in ubuntu-base
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    gnupg \
    libssl-dev \
    libstdc++-14-dev \
    lsb-release \
    pciutils \
    python3-setuptools \
    python3-wheel

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

# NVIDIA CUDA repository (ubuntu2404 / noble)
# The apt retry settings above do not cover wget, and its defaults are a 900s
# read timeout over 20 tries: a stalled Akamai edge hangs the build for hours
# instead of failing. Bound it and let it pick a different edge on retry.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    wget --progress=dot:giga --timeout=30 --tries=5 --retry-connrefused \
        -O /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && apt-get update

# AMD ROCm repository — therock stream (repo.amd.com) or legacy (repo.radeon.com)
RUN mkdir -p /etc/apt/keyrings && \
    if [ "${ROCM_STREAM}" = "therock" ]; then \
        curl -fsSL --retry 5 --retry-connrefused --max-time 120 \
            https://stable.repo.amd.com/rocm/gpg/packages.gpg \
            | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg && \
        printf 'Types: deb\nURIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2404\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/amdrocm.gpg\n' \
            > /etc/apt/sources.list.d/rocm.sources; \
    else \
        curl -fsSL --retry 5 --retry-connrefused --max-time 120 \
            https://repo.radeon.com/rocm/rocm.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg && \
        printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/%s %s main\n' \
            "${ROCM_VERSION}" "${UBUNTU_CODENAME}" \
            > /etc/apt/sources.list.d/rocm.list && \
        printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
            > /etc/apt/preferences.d/rocm-pin-600; \
    fi

# CUDA toolkit (dev only; no kernel driver)
#
# cuda-compat is NVIDIA's CUDA Forward Compatibility package. The toolkit
# itself ships only a link-time stub for libcuda, so anything linking -lcuda
# cannot even start without the host driver. cuda-compat provides a real
# libcuda.so.1 under ${CUDA_PATH}/compat, which lets such binaries run on a
# host with no NVIDIA driver at all (AMD-only machines, CI runners) while
# still deferring to the host driver when one is injected -- see the
# lowest-precedence ld.so.conf entry further down.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    CUDA_PKG_VER=$(cat /etc/cuda-version); \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "cuda-toolkit-${CUDA_PKG_VER}"; \
    if apt-get install -y --no-install-recommends \
            "cuda-compat-${CUDA_PKG_VER}"; then \
        echo "yes" > /etc/cuda-compat-installed; \
    else \
        echo "no" > /etc/cuda-compat-installed; \
        echo "WARNING: cuda-compat-${CUDA_PKG_VER} unavailable; binaries" \
             "linking -lcuda will require a host NVIDIA driver." >&2; \
    fi

# ROCm development stack (dev only; no drivers)
# therock stream meta package is 'amdrocm'; legacy stream is 'rocm' (or versioned variant)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
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
        "$@"; \
    update-pciids

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

# Linker configuration.
#
# The compat directory is deliberately a separate 'zz-' file: ld.so.conf.d is
# processed in glob (alphabetical) order, so it sorts after
# x86_64-linux-gnu.conf and the compat libcuda loses to a host driver that
# nvidia-container-toolkit mounts into /usr/lib/x86_64-linux-gnu. With no
# host driver, compat is the only libcuda.so.1 and wins by default.
RUN set -eux; \
    ROCM_ROOT=$(cat /etc/rocm-path); \
    CUDA_ROOT=$(cat /etc/cuda-path); \
    printf '%s/lib\n%s/lib64\n' "${ROCM_ROOT}" "${ROCM_ROOT}" \
        > /etc/ld.so.conf.d/rocm.conf; \
    printf '%s/lib64\n' "${CUDA_ROOT}" > /etc/ld.so.conf.d/cuda.conf; \
    if [ -d "${CUDA_ROOT}/compat" ]; then \
        printf '%s/compat\n' "${CUDA_ROOT}" \
            > /etc/ld.so.conf.d/zz-cuda-compat.conf; \
    fi; \
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
