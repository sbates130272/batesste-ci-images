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
ARG ROCJITSU_COMMIT=73c3cf3da4bf65a06bc41421bbd65d5e13baadaf
# Which config the vfio-user probe below and the default CMD serve. A build
# variant pinned to a different upstream ref can point at a renamed or newly
# added profile from images.yml without editing this file.
ARG ROCJITSU_CONFIG=gfx1250_mi455x.json
# Compile-time log groups; see rj_log.cmake. Nothing gates these at runtime, so
# a group named here prints for every event it covers.
ARG ROCJITSU_LOG_GROUPS=OFF
# Large BAR. Upstream ships the served config at 256 MiB -- the small-BAR
# ceiling -- and that is a config field, not a flag, so the only way to ship a
# large-BAR device is to rewrite it before the image is sealed. `max` is the
# largest power of two within the modelled device's own memory, which is what
# rocjitsu's two startup warnings bound it to.
#
# Defaults to `keep` -- upstream's value, untouched -- because the guest side
# cannot place a 256 GiB BAR yet: behind qemu-tool's pcie-root-port, with no
# raised phys-bits and no pci-hole64-size, the guest fails to assign BAR0 and
# BAR2 both and is left with no VRAM window at all. Opt in only where QEMU is
# driven by hand. See the README.
ARG ROCJITSU_VRAM_APERTURE_BYTES=keep

# Optional, and empty by default: build against a libvfio-user of our choosing
# instead of the one emulation/rocjitsu/cmake/rj_libvfio_user.cmake pins
# (nutanix/libvfio-user at v0.8). Set only by the -sbates-fork variant, to pick
# up VFIO_USER_HOST_DOORBELL_FD (opcode 19) and vfu_setup_host_doorbell_cb().
# See images.yml.
#
# Both or neither: a commit with no repo has nothing to fetch it from, and a
# repo with no commit would track a force-pushed branch.
#
# The upstream tree is still built unmodified -- this goes in through
# FETCHCONTENT_SOURCE_DIR_LIBVFIO-USER below, CMake's own escape hatch, rather
# than by patching the cmake that declares the pin.
ARG LIBVFIO_USER_REPO=
ARG LIBVFIO_USER_COMMIT=

WORKDIR /build

# The libvfio-user fetch is folded into this RUN rather than given one of its
# own: a new layer here would invalidate every layer below it on the default
# path too, where these ARGs are empty and nothing is fetched.
RUN git init /build/rocm-systems && \
    git -C /build/rocm-systems remote add origin "${ROCJITSU_REPO}" && \
    git -C /build/rocm-systems fetch --depth 1 origin "${ROCJITSU_COMMIT}" && \
    git -C /build/rocm-systems checkout FETCH_HEAD && \
    git -C /build/rocm-systems rev-parse HEAD \
        > /build/rocjitsu-commit.txt && \
    if [ -n "${LIBVFIO_USER_REPO}" ] && [ -n "${LIBVFIO_USER_COMMIT}" ]; then \
        git init /build/libvfio-user && \
        git -C /build/libvfio-user \
            fetch --depth 1 "${LIBVFIO_USER_REPO}" "${LIBVFIO_USER_COMMIT}" && \
        git -C /build/libvfio-user checkout FETCH_HEAD && \
        git -C /build/libvfio-user rev-parse HEAD \
            > /build/libvfio-user-commit.txt && \
        echo "${LIBVFIO_USER_REPO}" > /build/libvfio-user-source.txt; \
    else \
        echo rocjitsu-cmake > /build/libvfio-user-source.txt; \
    fi

# This tree is built unmodified. It used to carry a five-patch series against
# ROCJITSU_COMMIT without which the served device could not boot a guest, let
# alone run a kernel needing private memory; all five are in develop now. If a
# future head regresses, re-add the series and a pin freeze together -- git log
# for the patches/ directory.

# _Static_assert is a C11 keyword with no C++ spelling, and libvfio-user v0.8's
# pci_caps/{common,msix}.h use it; rocjitsu includes those from C++ in
# lib/rocjitsu/src/rocjitsu/vmm/vfu/vfio_device_host.cpp, so the VFIO build does
# not compile without this define. It is load-bearing for the default build and
# inert for the -sbates-fork variant: upstream 8039244 added include/compiler.h
# and replaced those assertions with VFU_STATIC_ASSERT, which already spells
# itself static_assert under __cplusplus. Inert rather than removable, because
# the flag is shared by both and the default still needs it. It reaches only
# CMAKE_CXX_FLAGS, never the C compile of lib/*.c, so it cannot collide with
# glibc's own static_assert macro either way.
#
# FETCHCONTENT_SOURCE_DIR_LIBVFIO-USER is CMake's documented per-dependency
# override: FetchContent upper-cases the declared name (`libvfio-user`) and
# consults this variable before downloading, so a non-empty value makes it use
# that tree and fetch nothing. The hyphen is legal in a CMake variable name.
# Empty is exactly equivalent to not passing the flag, which is what keeps the
# default path byte-identical to what it was before this hook existed.
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
    "-DFETCHCONTENT_SOURCE_DIR_LIBVFIO-USER=${LIBVFIO_USER_COMMIT:+/build/libvfio-user}" \
    -DROCJITSU_ENABLE_VFIO=ON \
    "-DRJ_LOG_GROUPS=${ROCJITSU_LOG_GROUPS}" \
    -DBUILD_TESTING=OFF && \
    cmake --build /build/rocm-systems/build \
          --parallel "$(nproc)" && \
    cmake --install /build/rocm-systems/build && \
    ldconfig

# Prove the override actually took, because every way it can fail is silent: an
# ignored variable, a misspelled name or a stale cache would all fall back to
# downloading v0.8 and produce a perfectly green build of the wrong library.
# Asserted against the CMakeCache -- what cmake resolved -- rather than against
# the flag we passed.
#
# `test ! -e` says FetchContent created no -src for THIS dependency; /tmp/deps
# itself exists either way, because json-c, googletest and flatbuffers land
# there too. The grep for the new symbol is the positive half: it is what the
# variant exists for, and it is absent from v0.8.
RUN set -eu; \
    if [ -n "${LIBVFIO_USER_COMMIT}" ]; then \
        grep -q 'FETCHCONTENT_SOURCE_DIR_LIBVFIO-USER:.*=/build/libvfio-user' \
            /build/rocm-systems/build/CMakeCache.txt; \
        test ! -e /tmp/deps/libvfio-user-src; \
        grep -q 'vfu_setup_host_doorbell_cb' \
            /build/libvfio-user/include/libvfio-user.h; \
        grep -q 'VFIO_USER_HOST_DOORBELL_FD' \
            /build/libvfio-user/include/vfio-user.h; \
    else \
        test -d /tmp/deps/libvfio-user-src; \
    fi

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

# Give the served device a large BAR, by rewriting the only thing that decides
# it. The helper ships rather than being inlined because the same rewrite is
# what an operator needs to try a different window against a running stack, and
# because it is where the power-of-two and <= local_mem_size rules are stated
# once -- rocjitsu only warns about both and serves anyway, so a bad value
# reaches a guest as a BAR that silently does not map rather than as a failure.
#
# Only the config this image serves is touched, whichever ROCJITSU_CONFIG
# names -- the window is computed from that profile's own memory rather than
# from a constant, so repointing the var needs no edit here. The other profiles
# are deliberately left alone: gfx1250_mi455x.json is the only one upstream
# gives a vm.gpu.pci block at all, and the only one that can be served over
# vfio-user. Every other gfx target warns "has no IP discovery profile ... a
# guest driver would find nothing to attach to", and gfx1250_mi455x_kmd_4gpu
# -- the one other 120500 profile -- exits 1 unmodified, because it describes
# four GPUs and this transport presents one function. A BAR on any of them
# would size a window no guest can reach.
#
# Asserted after the fact, against the file, because every failure mode here is
# quiet: a renamed key would leave a JSON document that still parses, still
# serves, and still has a 256 MiB BAR.
#
# The readback tolerates an absent pci block, which is the common case now that
# the default is `keep`: gfx1250_mi455x.json is the only profile upstream gives
# one, so repointing ROCJITSU_CONFIG anywhere else leaves nothing to read and 0
# is what the schema means by it -- an implementation-chosen window of at most
# 256 MiB.
COPY ubuntu-rocm-rocjitsu/rocjitsu-vram-aperture.py \
     /usr/local/bin/rocjitsu_vram_aperture.py
RUN set -eu; \
    chmod 0755 /usr/local/bin/rocjitsu_vram_aperture.py; \
    python3 /usr/local/bin/rocjitsu_vram_aperture.py \
        --config "${ROCJITSU_CONFIG_PATH}" \
        --bytes "${ROCJITSU_VRAM_APERTURE_BYTES}"; \
    aperture=$(python3 -c \
        'import json,sys;print(json.load(open(sys.argv[1]))["vm"]["gpu"].get("pci",{}).get("vram_aperture_bytes",0))' \
        "${ROCJITSU_CONFIG_PATH}"); \
    if [ "${ROCJITSU_VRAM_APERTURE_BYTES}" = max ]; then \
        mem=$(python3 -c \
            'import json,sys;print(json.load(open(sys.argv[1]))["vm"]["gpu"]["device"]["local_mem_size"])' \
            "${ROCJITSU_CONFIG_PATH}"); \
        test "${aperture}" -le "${mem}"; \
        test "$((aperture * 2))" -gt "${mem}"; \
    fi; \
    echo "${aperture}" > /usr/local/share/rocjitsu-vram-aperture.txt

# The dependency tags are read out of the cmake that pins them rather than
# restated here, so a bump upstream cannot leave this metadata lying about what
# the vfio-user transport was built against.
#
# read_pin walks the whole FetchContent_Declare block and takes its GIT_TAG,
# rather than assuming the tag is on the line after the repository URL. The
# naive version printed the first word of whatever followed, so a comment
# between GIT_REPOSITORY and GIT_TAG -- which the doorbell branch adds -- made
# it emit "Rebased" and sail past the `test -n` below. Order-independent and
# comment-proof, and still empty for a dependency that is not there, which is
# what that test is for.
#
# That awk reads the *recipe*, not what was fetched, so on its own it would
# report v0.8 for a -sbates-fork build that actually linked the fork -- a green
# build whose own provenance lies. So it now names both: libvfio_user_upstream_tag
# is what the tree declares, libvfio_user_tag is what was really built, and
# libvfio_user_source says which of the two supplied it.
#
# local_patches stays in the schema and stays empty. Consumers grew a habit of
# reading it to tell a patched build from an unpatched one, and an absent key
# reads the same as an unpatched image to a careless `.get()`; an explicit []
# says the tree was built unmodified -- which stays true under the override,
# because FETCHCONTENT_SOURCE_DIR redirects the fetch without touching the
# rocm-systems checkout.
RUN set -eu; \
    cmake_pins=/build/rocm-systems/emulation/rocjitsu/cmake/rj_libvfio_user.cmake; \
    read_pin() { awk -v url="$1" '/FetchContent_Declare\(/{inblk=1;tag="";hit=0;next} inblk{ if(index($0,url)) hit=1; if($1=="GIT_TAG") tag=$2; if($0 ~ /^[[:space:]]*\)/){ if(hit && tag!=""){print tag; exit} inblk=0 } }' "$2"; }; \
    libvfio_user_tag="$(read_pin libvfio-user.git "${cmake_pins}")"; \
    json_c_tag="$(read_pin json-c.git "${cmake_pins}")"; \
    test -n "${libvfio_user_tag}"; \
    test -n "${json_c_tag}"; \
    libvfio_user_upstream_tag="${libvfio_user_tag}"; \
    if [ -s /build/libvfio-user-commit.txt ]; then \
        libvfio_user_tag="$(cat /build/libvfio-user-commit.txt)"; \
    fi; \
    cp /build/rocjitsu-commit.txt /usr/local/share/rocjitsu-commit.txt; \
    printf '{\n\
  "rocjitsu_repo": "%s",\n\
  "rocjitsu_branch": "%s",\n\
  "rocjitsu_commit": "%s",\n\
  "local_patches": [],\n\
  "libvfio_user_source": "%s",\n\
  "libvfio_user_upstream_tag": "%s",\n\
  "libvfio_user_tag": "%s",\n\
  "json_c_tag": "%s",\n\
  "vfio_enabled": true,\n\
  "vram_aperture_bytes": %s,\n\
  "log_groups": "%s",\n\
  "guest_tools": ["rj-ip-discovery", "run-vfio-guest.py", "vfio_guest_firmware.py"],\n\
  "firmware_sets": ["gap", "full"],\n\
  "firmware_min_amdgpu_release": "31.60",\n\
  "config_dir": "%s"\n\
}\n' \
        "${ROCJITSU_REPO}" \
        "${ROCJITSU_BRANCH}" \
        "$(cat /build/rocjitsu-commit.txt)" \
        "$(cat /build/libvfio-user-source.txt)" \
        "${libvfio_user_upstream_tag}" \
        "${libvfio_user_tag}" \
        "${json_c_tag}" \
        "$(cat /usr/local/share/rocjitsu-vram-aperture.txt)" \
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
#
# The log is also the only place the BAR window is adjudicated. rocjitsu
# accepts an aperture larger than the modelled memory, or one that is not a
# power of two, and serves anyway -- it says so once, as a warning, and that
# warning is the whole signal. So anything matching 'aperture' here fails the
# build; at a good value rocjitsu says nothing about it at all.
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
    if grep -q aperture /tmp/probe.log; then \
        echo "rocjitsu rejected the VRAM aperture; see the warning above" >&2; \
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

RUN rm -rf /build/rocm-systems /build/libvfio-user /tmp/deps

ENV PATH=/usr/local/bin:${PATH}

# sh -c so ROCJITSU_CONFIG_PATH expands; exec so rocjitsu still ends up as PID 1
# and libvfio-user gets the SIGTERM that unlinks its socket on teardown.
CMD ["sh", "-c", \
     "exec rocjitsu --config \"${ROCJITSU_CONFIG_PATH}\" \
      --vfio-socket \"${ROCJITSU_SOCKET_DIR}/rocjitsu.sock\""]
