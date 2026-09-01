ARG BASE_IMAGE=docker.io/batesste/batesste-ci-images-ubuntu-cuda-rocm:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

ARG FIO_REPO=https://github.com/axboe/fio.git
# libhipfile landed on fio master (67256d4e, 2026-05-08) and is not in any
# release tag yet, so this must be a master commit rather than fio-3.x.
ARG FIO_COMMIT=ae35a58399b28edf857f7ebc43b3eb40d86ac29b
ARG CACHE_BUST=

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/fio_cache_bust.txt

# hipFile ships only in the therock ROCm stream; fail early and clearly when
# the base image was built with ROCM_STREAM=legacy.
RUN set -eux; \
    apt-get update; \
    if ! apt-cache show amdrocm-hipfile-dev > /dev/null 2>&1; then \
        echo "ERROR: amdrocm-hipfile-dev is unavailable. This image requires a" \
             "base built with ROCM_STREAM=therock." >&2; \
        exit 1; \
    fi; \
    apt-get install -y --no-install-recommends \
        amdrocm-hipfile-dev \
        libaio-dev \
        libnuma-dev \
        pkg-config \
        zlib1g-dev; \
    ldconfig; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Increase git HTTP buffer and disable low-speed cutoff for large clones through proxy
RUN git config --global http.postBuffer 524288000 && \
    git config --global http.lowSpeedLimit 0 && \
    git config --global http.lowSpeedTime 0

RUN git init /build/fio && \
    git -C /build/fio remote add origin "${FIO_REPO}" && \
    git -C /build/fio fetch --depth 1 origin "${FIO_COMMIT}" && \
    git -C /build/fio checkout FETCH_HEAD && \
    git -C /build/fio rev-parse HEAD > /build/fio-commit.txt

# --enable-* makes each probe hard-fail rather than silently drop the engine.
# fio's own libhipfile probe adds -rpath ${ROCM_PATH}/lib; the CUDA side needs
# explicit paths because configure hardcodes bare -lcuda -lcudart -lcufile.
# hadolint ignore=DL3003
RUN set -eux; \
    ROCM_PATH="$(cat /etc/rocm-path)"; export ROCM_PATH; \
    CUDA_PATH="$(cat /etc/cuda-path)"; \
    cd /build/fio; \
    ./configure \
        --extra-cflags="-I${CUDA_PATH}/include" \
        --extra-ldflags="-L${CUDA_PATH}/lib64 -L${CUDA_PATH}/lib64/stubs -Wl,-rpath,${CUDA_PATH}/lib64" \
        --enable-cuda \
        --enable-libcufile \
        --enable-libhipfile; \
    make -j"$(nproc)"; \
    make install prefix=/usr/local

# fio links -lcuda unconditionally once CUDA support is enabled, so the binary
# carries DT_NEEDED libcuda.so.1 and will not start without a driver. Keep a
# stub off the default linker path so driverless smoke tests can opt in via
# LD_LIBRARY_PATH without shadowing a real driver on GPU hosts.
RUN set -eux; \
    CUDA_PATH="$(cat /etc/cuda-path)"; \
    mkdir -p /opt/fio/cuda-stubs; \
    ln -sf "${CUDA_PATH}/lib64/stubs/libcuda.so" /opt/fio/cuda-stubs/libcuda.so.1

RUN set -eux; \
    cp /build/fio-commit.txt /usr/local/share/fio-commit.txt; \
    LD_LIBRARY_PATH=/opt/fio/cuda-stubs fio --enghelp \
        > /usr/local/share/fio-engines.txt; \
    grep -qE '^[[:space:]]*libhipfile$' /usr/local/share/fio-engines.txt; \
    grep -qE '^[[:space:]]*libcufile$' /usr/local/share/fio-engines.txt; \
    rm -rf /build/fio

CMD ["fio", "--version"]
