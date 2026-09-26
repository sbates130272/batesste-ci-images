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
ARG ROCJITSU_BRANCH=develop
# The head of the branch. The review branch this used to track
# (users/agutierr/gfx1250-vfio-compute-6) was squashed onto develop as
# bdc4aea25 "harden PCI and VFIO compute transport" and d5927b503 "qualify the
# QEMU VFIO compute workflow", and then deleted, so the old pin is not an
# ancestor of anything that still exists.
ARG ROCJITSU_COMMIT=fafcb3f6e08ec314968040df4b4fd1b7319199ec
# Which config the vfio-user probe below and the default CMD serve. A build
# variant pinned to a different upstream ref can point at a renamed or newly
# added profile from images.yml without editing this file.
ARG ROCJITSU_CONFIG=gfx1250_mi455x.json
# Compile-time log groups; see rj_log.cmake. Nothing gates these at runtime, so
# a group named here prints for every event it covers.
ARG ROCJITSU_LOG_GROUPS=OFF

WORKDIR /build

RUN git init /build/rocm-systems && \
    git -C /build/rocm-systems remote add origin "${ROCJITSU_REPO}" && \
    git -C /build/rocm-systems fetch --depth 1 origin "${ROCJITSU_COMMIT}" && \
    git -C /build/rocm-systems checkout FETCH_HEAD && \
    git -C /build/rocm-systems rev-parse HEAD \
        > /build/rocjitsu-commit.txt

# This tree is built unmodified. It used to carry a five-patch series against
# ROCJITSU_COMMIT without which the served device could not boot a guest, let
# alone run a kernel needing private memory; all five are in develop now. If a
# future head regresses, re-add the series and a pin freeze together -- git log
# for the patches/ directory.

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
        /usr/local/bin/run-vfio-guest.py

# vfio_guest_firmware.py covers what the guest's own driver release does not.
# amdgpu parses GFX/SDMA/MES firmware headers during early init even in
# emulation mode, and develop's qemu-vfio.md hands that step to the operator:
# "use the firmware files from the same public driver release as the guest's
# amdgpu.ko". From amdgpu 31.60 that release exists -- amdgpu-dkms-firmware
# ships real gc_12_1_0 mec/mec_1/rlc/rlc_1/uni_mes and sdma_7_1_0, and
# amdgpu-dkms depends on it, so the guest gets them without being asked. Two
# files it does not ship are still opened: gc_12_1_0_imu.bin, which is
# AMDGPU_UCODE_REQUIRED under the amdgpu.fw_load_type=0 that doc prescribes,
# and ip_discovery.bin, which comes from rj-ip-discovery. That gap is the
# default output; --set full still emits the whole stub set for a guest on a
# release older than 31.60.
#
# The fixture builders are upstream's, vendored at 730bc62 rather than fetched.
# The file was deleted upstream, so fetching it means fetching from a commit on
# a branch that has already been deleted once and can be pruned at any time.
# Nothing upstream will restore it: develop has no executable firmware handling
# anywhere and no CI that enables ROCJITSU_ENABLE_VFIO, so this is ours to own.
COPY ubuntu-rocm-rocjitsu/vfio-guest-firmware.py \
     /usr/local/bin/vfio_guest_firmware.py
RUN chmod 0755 /usr/local/bin/vfio_guest_firmware.py

# Acceptance test for the dynamic-scratch path, shipped beside the server
# because that is what a consumer has in hand when a dispatch never retires. It
# is a guest-side artefact -- there is no hipcc here and no GPU to run it on --
# so it is only staged: copy it into the guest and build it there. It was
# written against the local patch that first made this path work and is kept
# now that upstream carries its own: on a server that does not ask the runtime
# for scratch it hangs forever with no error, which is the whole reason it
# exists.
COPY ubuntu-rocm-rocjitsu/rocjitsu-scratch-repro.hip \
     /usr/local/share/rocjitsu/rocjitsu-scratch-repro.hip

# Upstream's install(DIRECTORY configs/) already placed the configs.
ENV ROCJITSU_CONFIG_DIR=/usr/local/share/rocjitsu/configs
ENV ROCJITSU_SOCKET_DIR=/run/rocjitsu
ENV ROCJITSU_CONFIG_PATH=${ROCJITSU_CONFIG_DIR}/${ROCJITSU_CONFIG}

# The dependency tags are read out of the cmake that pins them rather than
# restated here, so a bump upstream cannot leave this metadata lying about what
# the vfio-user transport was built against.
#
# local_patches stays in the schema and stays empty. Consumers grew a habit of
# reading it to tell a patched build from an unpatched one, and an absent key
# reads the same as an unpatched image to a careless `.get()`; an explicit []
# says the tree was built unmodified.
RUN set -eu; \
    cmake_pins=/build/rocm-systems/emulation/rocjitsu/cmake/rj_libvfio_user.cmake; \
    libvfio_user_tag="$(awk '/libvfio-user.git/{getline; print $2}' "${cmake_pins}")"; \
    json_c_tag="$(awk '/json-c.git/{getline; print $2}' "${cmake_pins}")"; \
    test -n "${libvfio_user_tag}"; \
    test -n "${json_c_tag}"; \
    cp /build/rocjitsu-commit.txt /usr/local/share/rocjitsu-commit.txt; \
    printf '{\n\
  "rocjitsu_repo": "%s",\n\
  "rocjitsu_branch": "%s",\n\
  "rocjitsu_commit": "%s",\n\
  "local_patches": [],\n\
  "libvfio_user_tag": "%s",\n\
  "json_c_tag": "%s",\n\
  "vfio_enabled": true,\n\
  "log_groups": "%s",\n\
  "guest_tools": ["rj-ip-discovery", "run-vfio-guest.py", "vfio_guest_firmware.py"],\n\
  "firmware_sets": ["gap", "full"],\n\
  "firmware_min_amdgpu_release": "31.60",\n\
  "config_dir": "%s"\n\
}\n' \
        "${ROCJITSU_REPO}" \
        "${ROCJITSU_BRANCH}" \
        "$(cat /build/rocjitsu-commit.txt)" \
        "${libvfio_user_tag}" \
        "${json_c_tag}" \
        "${ROCJITSU_LOG_GROUPS}" \
        "${ROCJITSU_CONFIG_DIR}" \
        > /usr/local/share/rocjitsu-build.json; \
    cat /usr/local/share/rocjitsu-build.json; \
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
# The firmware generator is exercised the same way, in both sets. Each output
# is asserted against its own manifest rather than a list repeated here: a
# guest missing any one of these files fails in amdgpu's early init with a
# firmware load error, and the point of the manifest is that adding a file
# needs no edit in the places that check for it.
#
# What is asserted by name is what the manifest cannot state. gc_12_1_0_imu.bin
# has to be in the default set, because it is the one file no driver release
# ships and the whole reason the default set exists; the packaged names have to
# be absent from it, because writing a sentinel stub over real microcode is
# strictly worse than not writing it. The aliases have to carry their source's
# bytes. And a config this generator has no firmware for has to be refused
# rather than served gfx1250 stubs under a different GPU's name.
#
# --generation is the path the ernic-rocjitsu guest build takes, where no
# rocjitsu config exists to read. It has to produce the same bytes the config
# path does and be refused on the same unsupported generations: nothing
# downstream of it can tell the two apart.
RUN set -eux; \
    rj-ip-discovery gfx1250 /tmp/ip_discovery.bin; \
    test -s /tmp/ip_discovery.bin; \
    run-vfio-guest.py --help > /dev/null; \
    for fwset in gap full; do \
        out=/tmp/fw-${fwset}; \
        python3 /usr/local/bin/vfio_guest_firmware.py --set "${fwset}" --output "${out}"; \
        listed=$(python3 -c \
            'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["files"]))' \
            "${out}/manifest.json"); \
        for fw in ${listed}; do test -s "${out}/${fw}"; done; \
        test "$(ls "${out}" | grep -v '^manifest\.json$' | sort)" \
           = "$(printf '%s\n' ${listed} | sort)"; \
        test -s "${out}/gc_12_1_0_imu.bin"; \
        test -s "${out}/ip_discovery.bin"; \
    done; \
    test ! -e /tmp/fw-gap/gc_12_1_0_uni_mes.bin; \
    test ! -e /tmp/fw-gap/sdma_7_1_0.bin; \
    cmp /tmp/fw-full/gc_12_1_0_mes.bin /tmp/fw-full/gc_12_1_0_uni_mes.bin; \
    cmp /tmp/fw-full/gc_12_1_0_mes1.bin /tmp/fw-full/gc_12_1_0_uni_mes.bin; \
    cmp /tmp/fw-full/gc_12_1_0_mec_1.bin /tmp/fw-full/gc_12_1_0_mec.bin; \
    cmp /tmp/fw-full/gc_12_1_0_rlc.bin /tmp/fw-full/gc_12_1_0_rlc_1.bin; \
    ! python3 /usr/local/bin/vfio_guest_firmware.py \
        --config gfx950_mi355x.json --output /tmp/fw-unsupported; \
    test ! -e /tmp/fw-unsupported; \
    python3 /usr/local/bin/vfio_guest_firmware.py \
        --generation gfx1250 --no-ip-discovery --output /tmp/fw-gen; \
    cmp /tmp/fw-gen/gc_12_1_0_imu.bin /tmp/fw-gap/gc_12_1_0_imu.bin; \
    cmp /tmp/fw-gen/gc_12_1_0_mes.bin /tmp/fw-gap/gc_12_1_0_mes.bin; \
    cmp /tmp/fw-gen/gc_12_1_0_mes1.bin /tmp/fw-gap/gc_12_1_0_mes1.bin; \
    test ! -e /tmp/fw-gen/ip_discovery.bin; \
    test "$(python3 -c \
        'import json,sys;print(json.load(open(sys.argv[1]))["gfx_target_version"])' \
        /tmp/fw-gen/manifest.json)" = "$(python3 -c \
        'import json,sys;print(json.load(open(sys.argv[1]))["gfx_target_version"])' \
        /tmp/fw-gap/manifest.json)"; \
    ! python3 /usr/local/bin/vfio_guest_firmware.py \
        --generation gfx950 --no-ip-discovery --output /tmp/fw-unsupported-gen; \
    test ! -e /tmp/fw-unsupported-gen; \
    rm -rf /tmp/ip_discovery.bin /tmp/fw-gap /tmp/fw-full /tmp/fw-gen

# Three upstream behaviours are the difference between an image that serves a
# device and one a guest can boot and run kernels on. They replaced the local
# series this image used to carry, and nothing upstream tests them: no CI
# anywhere enables ROCJITSU_ENABLE_VFIO, so a refactor on develop can take any
# of them away with every check still green. Assert them here, where the
# failure names what is missing, rather than as "Timeout waiting for VM flush
# ACK!" or a dispatch that never retires.
#
# Grepping source is crude, but these are behaviours with no runtime probe
# short of booting a guest, and each marker is the identifier the behaviour is
# implemented under rather than incidental text.
RUN set -eux; \
    src=/build/rocm-systems/emulation/rocjitsu; \
    vm=${src}/lib/rocjitsu/src/rocjitsu/vm/amdgpu; \
    unpatched=$(python3 -c \
        'import json;print(len(json.load(open("/usr/local/share/rocjitsu-build.json"))["local_patches"]))'); \
    test "${unpatched}" -eq 0; \
    grep -q 'kPageTableRootFlags' "${vm}/gpu_vm.cpp"; \
    grep -q 'RoutesAddressesOutsideTheGartApertureToVram' \
        "${src}/tests/pci/gpu_pci_device_test.cpp"; \
    grep -q 'request_dynamic_scratch' "${vm}/command_processor.cpp"

RUN rm -rf /build/rocm-systems /tmp/deps

ENV PATH=/usr/local/bin:${PATH}

# sh -c so ROCJITSU_CONFIG_PATH expands; exec so rocjitsu still ends up as PID 1
# and libvfio-user gets the SIGTERM that unlinks its socket on teardown.
CMD ["sh", "-c", \
     "exec rocjitsu --config \"${ROCJITSU_CONFIG_PATH}\" \
      --vfio-socket \"${ROCJITSU_SOCKET_DIR}/rocjitsu.sock\""]
