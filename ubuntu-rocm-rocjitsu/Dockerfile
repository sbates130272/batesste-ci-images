FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    g++-14 \
    gcc-14 \
    git \
    libclang-rt-dev \
    libdrm-dev \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

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

ARG ROCJITSU_REPO=https://github.com/ROCm/rocm-systems.git
ARG ROCJITSU_BRANCH=develop
ARG ROCJITSU_COMMIT=5e9cc7c57d372c0198fd8decb1fe5ceb07038a2b

WORKDIR /build

# Increase git HTTP buffer and disable low-speed cutoff for large clones through proxy
RUN git config --global http.postBuffer 524288000 && \
    git config --global http.lowSpeedLimit 0 && \
    git config --global http.lowSpeedTime 0

RUN git init /build/rocm-systems && \
    git -C /build/rocm-systems remote add origin "${ROCJITSU_REPO}" && \
    git -C /build/rocm-systems fetch --depth 1 origin "${ROCJITSU_COMMIT}" && \
    git -C /build/rocm-systems checkout FETCH_HEAD && \
    git -C /build/rocm-systems rev-parse HEAD \
        > /build/rocjitsu-commit.txt

# _Static_assert is a C11 keyword with no C++ spelling, and libvfio-user v0.8's
# pci_caps/{common,msix}.h use it; rocjitsu includes those from C++ in
# lib/rocjitsu/src/rocjitsu/vmm/vfu/vfio_device_host.cpp, so the VFIO build does
# not compile without this define.
RUN cmake \
    -B /build/rocm-systems/build \
    -G Ninja \
    -S /build/rocm-systems/emulation/rocjitsu \
    -DCMAKE_C_COMPILER=gcc-14 \
    -DCMAKE_CXX_COMPILER=g++-14 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_SCAN_FOR_MODULES=OFF \
    "-DCMAKE_CXX_FLAGS=-D_Static_assert=static_assert" \
    "-DCMAKE_SHARED_LINKER_FLAGS=-static-libstdc++" \
    "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DFETCHCONTENT_BASE_DIR=/tmp/deps \
    -DROCJITSU_ENABLE_VFIO=ON \
    -DBUILD_TESTING=OFF && \
    cmake --build /build/rocm-systems/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-systems/build && \
    ldconfig

# Upstream's install(DIRECTORY configs/) already placed these; the tags come from
# emulation/rocjitsu/cmake/rj_libvfio_user.cmake, which pins what the vfio-user
# transport is actually built against.
ENV ROCJITSU_CONFIG_DIR=/usr/local/share/rocjitsu/configs
ENV ROCJITSU_SOCKET_DIR=/run/rocjitsu

RUN cp /build/rocjitsu-commit.txt \
        /usr/local/share/rocjitsu-commit.txt && \
    printf '{\n\
  "rocjitsu_repo": "%s",\n\
  "rocjitsu_branch": "%s",\n\
  "rocjitsu_commit": "%s",\n\
  "libvfio_user_tag": "v0.8",\n\
  "json_c_tag": "json-c-0.18-20240915",\n\
  "vfio_enabled": true,\n\
  "config_dir": "%s"\n\
}\n' \
        "${ROCJITSU_REPO}" \
        "${ROCJITSU_BRANCH}" \
        "$(cat /build/rocjitsu-commit.txt)" \
        "${ROCJITSU_CONFIG_DIR}" \
        > /usr/local/share/rocjitsu-build.json && \
    mkdir -p "${ROCJITSU_SOCKET_DIR}"

# Prove the vfio-user front end reaches a usable device, not just that it linked.
# Only gfx_target_version 120500 has an IP discovery profile upstream
# (kGfx1250TargetVersion in vm/amdgpu/pci/gpu_pci_device_spec.cpp); any other
# config leaves the device unusable and rocjitsu exits 1.
# The verdict has to be latched inside the loop: libvfio-user unlinks the socket
# on teardown, so re-testing it after the shutdown would always fail.
# hadolint ignore=DL3001
RUN rocjitsu --config "${ROCJITSU_CONFIG_DIR}/gfx1250_mi455x.json" \
             --vfio-socket /tmp/probe.sock > /tmp/probe.log 2>&1 & \
    probe_pid=$!; \
    served=0; \
    i=0; \
    while [ "$i" -lt 150 ]; do \
        if [ -S /tmp/probe.sock ] && grep -q 'vfu: serving' /tmp/probe.log; then \
            served=1; \
            break; \
        fi; \
        if ! kill -0 "$probe_pid" 2>/dev/null; then \
            break; \
        fi; \
        i=$((i + 1)); \
        sleep 0.1; \
    done; \
    kill -TERM "$probe_pid" 2>/dev/null; \
    wait "$probe_pid"; \
    cat /tmp/probe.log; \
    if [ "$served" -ne 1 ]; then \
        echo "rocjitsu did not serve a vfio-user device" >&2; \
        exit 1; \
    fi; \
    rm -f /tmp/probe.log

RUN rm -rf /build/rocm-systems /tmp/deps

ENV PATH=/usr/local/bin:${PATH}

CMD ["rocjitsu", \
     "--config", "/usr/local/share/rocjitsu/configs/gfx1250_mi455x.json", \
     "--vfio-socket", "/run/rocjitsu/rocjitsu.sock"]
