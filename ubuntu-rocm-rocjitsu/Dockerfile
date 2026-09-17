ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    clang \
    g++-14 \
    gcc-14 \
    libclang-rt-dev \
    libdrm-dev \
    python3

ARG ROCJITSU_REPO=https://github.com/ROCm/rocm-systems.git
ARG ROCJITSU_BRANCH=users/agutierr/gfx1250-vfio-compute-6
ARG ROCJITSU_COMMIT=be38974c9e74ef11bb27448d05264f9d3431dd0b
# Which config the vfio-user probe below and the default CMD serve. A build
# variant pinned to a different upstream ref can point at a renamed or newly
# added profile from images.yml without editing this file.
ARG ROCJITSU_CONFIG=gfx1250_mi455x.json
# The last upstream commit carrying emulation/rocjitsu/tools/
# vfio_guest_firmware.py, fetched separately from ROCJITSU_COMMIT because the
# stub generator was deleted upstream and no public firmware release replaces
# it for gfx1250. See the install step below.
ARG ROCJITSU_FIRMWARE_GEN_COMMIT=730bc62d60191337a07da50892538475370cb071
# Compile-time log groups; see rj_log.cmake. Nothing gates these at runtime, so
# a group named here prints for every event it covers.
ARG ROCJITSU_LOG_GROUPS=CP

WORKDIR /build

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
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    cmake \
    -B /build/rocm-systems/build \
    -G Ninja \
    -S /build/rocm-systems/emulation/rocjitsu \
    -DCMAKE_C_COMPILER=gcc-14 \
    -DCMAKE_CXX_COMPILER=g++-14 \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_SCAN_FOR_MODULES=OFF \
    "-DCMAKE_CXX_FLAGS=-D_Static_assert=static_assert" \
    "-DCMAKE_SHARED_LINKER_FLAGS=-static-libstdc++" \
    "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DFETCHCONTENT_BASE_DIR=/tmp/deps \
    -DROCJITSU_ENABLE_VFIO=ON \
    "-DRJ_LOG_GROUPS=${ROCJITSU_LOG_GROUPS}" \
    -DBUILD_TESTING=OFF && \
    cmake --build /build/rocm-systems/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-systems/build && \
    ldconfig

# rj-ip-discovery generates the ip_discovery.bin that amdgpu.discovery=2 reads
# instead of polling BAR registers; without it the driver stalls in
# gfx_v12_1_hw_init. run-vfio-guest.py is upstream's harness for booting a
# prepared guest against the vfio-user socket.
#
# vfio_guest_firmware.py generates the GFX/SDMA/MES header fixtures the driver
# parses during early init even in emulation mode. Upstream deleted it when
# qemu-vfio.md moved to "use firmware files from the same public driver release
# as the guest's amdgpu.ko" -- but no such release exists for gfx1250:
# amdgpu-dkms-firmware 31.50, the newest driver tree with a 26.04 suite, ships
# 683 files and not one gc_12_1_0 or sdma_7_1_0 among them. Stubs are therefore
# still the only way to boot the emulated device, which is why every consumer
# was pinning this image at rocjitsu.730bc62 to get the generator.
#
# Fetched from that commit rather than vendored, so the file stays attributable
# upstream, and separately from ROCJITSU_COMMIT so the server itself keeps
# tracking the head of the series.
#
# Upstream builds rj-ip-discovery (CMakeLists.txt add_subdirectory) but ships
# no install() rule for it -- only rocjitsu_bin and rj_pretranslate -- so it
# has to come out of the build tree by hand. Located rather than hardcoded so
# a rearranged build layout fails here instead of silently shipping nothing.
RUN set -eux; \
    rj_ip_discovery=$(find /build/rocm-systems/build \
        -type f -name rj-ip-discovery -perm -u+x -print -quit); \
    test -n "${rj_ip_discovery}"; \
    install -m 0755 "${rj_ip_discovery}" /usr/local/bin/rj-ip-discovery; \
    install -m 0755 \
        /build/rocm-systems/emulation/rocjitsu/scripts/run-vfio-guest.py \
        /usr/local/bin/run-vfio-guest.py; \
    git -C /build/rocm-systems fetch --depth 1 origin \
        "${ROCJITSU_FIRMWARE_GEN_COMMIT}"; \
    mkdir -p /usr/local/lib/rocjitsu; \
    git -C /build/rocm-systems show \
        "${ROCJITSU_FIRMWARE_GEN_COMMIT}:emulation/rocjitsu/tools/vfio_guest_firmware.py" \
        > /usr/local/lib/rocjitsu/vfio_guest_firmware_upstream.py; \
    chmod 0644 /usr/local/lib/rocjitsu/vfio_guest_firmware_upstream.py

# Upstream's generator lands on a library path and the wrapper takes the name
# consumers already call, because upstream's output is not a firmware set a
# guest can use as-is: it emits five fixtures under hardwired gfx12.1 names and
# nothing that says what they are. Every consumer then reinvents the same three
# facts about this device model -- fabricate the two MES names the driver opens,
# hardcode a filename to prove the set arrived, and name a generation on the
# rj-ip-discovery call -- and each is a place a change here silently breaks
# them. The wrapper emits the complete set, runs rj-ip-discovery for the
# generation it derived from the config, and writes a manifest naming every
# file. The fixture bytes stay upstream's: it calls upstream's builders.
COPY ubuntu-rocm-rocjitsu/vfio-guest-firmware.py \
     /usr/local/bin/vfio_guest_firmware.py
RUN chmod 0755 /usr/local/bin/vfio_guest_firmware.py

# Upstream's install(DIRECTORY configs/) already placed these; the tags come from
# emulation/rocjitsu/cmake/rj_libvfio_user.cmake, which pins what the vfio-user
# transport is actually built against.
ENV ROCJITSU_CONFIG_DIR=/usr/local/share/rocjitsu/configs
ENV ROCJITSU_SOCKET_DIR=/run/rocjitsu
ENV ROCJITSU_CONFIG_PATH=${ROCJITSU_CONFIG_DIR}/${ROCJITSU_CONFIG}

RUN cp /build/rocjitsu-commit.txt \
        /usr/local/share/rocjitsu-commit.txt && \
    printf '{\n\
  "rocjitsu_repo": "%s",\n\
  "rocjitsu_branch": "%s",\n\
  "rocjitsu_commit": "%s",\n\
  "libvfio_user_tag": "v0.8",\n\
  "json_c_tag": "json-c-0.18-20240915",\n\
  "vfio_enabled": true,\n\
  "log_groups": "%s",\n\
  "guest_tools": ["rj-ip-discovery", "run-vfio-guest.py", "vfio_guest_firmware.py"],\n\
  "firmware_gen_commit": "%s",\n\
  "config_dir": "%s"\n\
}\n' \
        "${ROCJITSU_REPO}" \
        "${ROCJITSU_BRANCH}" \
        "$(cat /build/rocjitsu-commit.txt)" \
        "${ROCJITSU_LOG_GROUPS}" \
        "${ROCJITSU_FIRMWARE_GEN_COMMIT}" \
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
RUN rocjitsu --config "${ROCJITSU_CONFIG_PATH}" \
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

# rj-ip-discovery is useless if it cannot produce its artefact, and a guest
# that gets an empty ip_discovery.bin hangs in hw_init rather than failing
# cleanly -- so prove it runs here, where the failure is legible.
# gfx1250 is asserted by name: it is the generation the served config models,
# and a rename upstream should break the build, not the guest.
# run-vfio-guest.py needs a kernel and initramfs it cannot have at build time,
# so --help is as far as it can be exercised -- enough to catch a Python the
# base image cannot import it under.
#
# The stub generator is exercised the same way. Its output is asserted against
# its own manifest rather than a list repeated here: a guest missing any one of
# these files fails in amdgpu's early init with a firmware load error, and the
# point of the manifest is that adding a file needs no edit in the places that
# check for it. What is still asserted by name is the property the manifest
# cannot state -- that the two MES aliases carry the uni_mes bytes -- and that
# a config this generator has no firmware for is refused rather than served
# gfx1250 stubs under a different GPU's name.
RUN set -eux; \
    rj-ip-discovery gfx1250 /tmp/ip_discovery.bin; \
    test -s /tmp/ip_discovery.bin; \
    run-vfio-guest.py --help > /dev/null; \
    python3 /usr/local/bin/vfio_guest_firmware.py --output /tmp/fw; \
    listed=$(python3 -c \
        'import json;print("\n".join(json.load(open("/tmp/fw/manifest.json"))["files"]))'); \
    for fw in ${listed}; do test -s "/tmp/fw/${fw}"; done; \
    test "$(ls /tmp/fw | grep -v '^manifest\.json$' | sort)" \
       = "$(printf '%s\n' ${listed} | sort)"; \
    cmp /tmp/fw/gc_12_1_0_mes.bin /tmp/fw/gc_12_1_0_uni_mes.bin; \
    cmp /tmp/fw/gc_12_1_0_mes1.bin /tmp/fw/gc_12_1_0_uni_mes.bin; \
    ! python3 /usr/local/bin/vfio_guest_firmware.py \
        --config gfx950_mi355x.json --output /tmp/fw-unsupported; \
    test ! -e /tmp/fw-unsupported; \
    rm -rf /tmp/ip_discovery.bin /tmp/fw

# The build check above imports the upstream generator, which leaves a
# __pycache__ beside it that a consumer would otherwise ship and never use.
RUN rm -rf /build/rocm-systems /tmp/deps /usr/local/lib/rocjitsu/__pycache__

ENV PATH=/usr/local/bin:${PATH}

# sh -c so ROCJITSU_CONFIG_PATH expands; exec so rocjitsu still ends up as PID 1
# and libvfio-user gets the SIGTERM that unlinks its socket on teardown.
CMD ["sh", "-c", \
     "exec rocjitsu --config \"${ROCJITSU_CONFIG_PATH}\" \
      --vfio-socket \"${ROCJITSU_SOCKET_DIR}/rocjitsu.sock\""]
