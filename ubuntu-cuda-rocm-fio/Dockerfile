ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-cuda-rocm:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

ARG FIO_REPO=https://github.com/axboe/fio.git
# libhipfile landed on fio master (67256d4e, 2026-05-08) and is not in any
# release tag yet, so this must be a master commit rather than fio-3.x.
# The asynchronous hipFile engine is not upstream at all: the
# ubuntu-cuda-rocm-fio@async-hipfile variant overrides both args to build it
# from a ROCm fork branch. Everything below is written to work either way.
ARG FIO_COMMIT=975ea1856fee9f4c0f01f6f19ba3c61ce24f9bc8
ARG CACHE_BUST=

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/fio_cache_bust.txt

# hipFile ships only in the therock ROCm stream; fail early and clearly when
# the base image was built with ROCM_STREAM=legacy.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
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
    ldconfig

WORKDIR /build

RUN git init /build/fio && \
    git -C /build/fio remote add origin "${FIO_REPO}" && \
    git -C /build/fio fetch --depth 1 origin "${FIO_COMMIT}" && \
    git -C /build/fio checkout FETCH_HEAD && \
    git -C /build/fio rev-parse HEAD > /build/fio-commit.txt

# --enable-* makes each probe hard-fail rather than silently drop the engine.
# fio's own libhipfile probe adds -rpath ${ROCM_PATH}/lib; the CUDA side needs
# explicit paths because configure hardcodes bare -lcuda -lcudart -lcufile.
# hadolint ignore=DL3003
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    set -eux; \
    ROCM_PATH="$(cat /etc/rocm-path)"; export ROCM_PATH; \
    CUDA_PATH="$(cat /etc/cuda-path)"; \
    PATH="/usr/lib/ccache:${PATH}"; export PATH; \
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
# carries DT_NEEDED libcuda.so.1. It runs here with no NVIDIA driver only
# because the base image installs cuda-compat, so simply invoking fio doubles
# as a check that compat is present and on the linker path.
RUN set -eux; \
    cp /build/fio-commit.txt /usr/local/share/fio-commit.txt; \
    ldd "$(command -v fio)" | grep -q 'libcuda\.so\.1 => /'; \
    fio --enghelp > /usr/local/share/fio-engines.txt; \
    grep -qE '^[[:space:]]*libhipfile$' /usr/local/share/fio-engines.txt; \
    grep -qE '^[[:space:]]*libcufile$' /usr/local/share/fio-engines.txt; \
    fio --enghelp=libhipfile > /usr/local/share/fio-libhipfile-help.txt

# Asynchronous submission (hipfile_mode=batch|stream) only exists on the ROCm
# fork branch. Record which build this is once, here, so neither the smoke
# script nor CI has to re-derive it from engine help at runtime. The examples
# and the sweep harness likewise ship only when the checkout carries them.
#
# --enghelp=<engine> lists options one line each; the mode names only appear
# when a single option is asked about, so that output is appended as well.
RUN set -eux; \
    if grep -q 'hipfile_mode' /usr/local/share/fio-libhipfile-help.txt; then \
        echo yes > /usr/local/share/fio-hipfile-async.txt; \
        fio --enghelp=libhipfile,hipfile_mode \
            >> /usr/local/share/fio-libhipfile-help.txt; \
    else \
        echo no > /usr/local/share/fio-hipfile-async.txt; \
    fi; \
    mkdir -p /usr/local/share/fio/examples; \
    for f in /build/fio/examples/libhipfile*.fio; do \
        if [ -e "$f" ]; then cp "$f" /usr/local/share/fio/examples/; fi; \
    done; \
    if [ -f /build/fio/fio_sweep.py ]; then \
        install -m 0755 /build/fio/fio_sweep.py /usr/local/bin/fio-sweep; \
    fi; \
    rm -rf /build/fio

COPY ubuntu-cuda-rocm-fio/hipfile-smoke.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/hipfile-smoke.sh

CMD ["fio", "--version"]
