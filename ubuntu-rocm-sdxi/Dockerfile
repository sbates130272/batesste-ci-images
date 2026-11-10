ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# zlib, lz4 and zstd are not optional: emulation/sdxi/CMakeLists.txt does a bare
# find_package(ZLIB REQUIRED) and two pkg_check_modules(... REQUIRED ...) for
# liblz4 and libzstd, so a missing one fails at configure rather than degrading
# to a build without the COMPRESS descriptor types.
# python3 is a *configure-time* requirement even though nothing here runs the
# test suite. emulation/sdxi/CMakeLists.txt ends with a bare
# `enable_testing()` + `add_subdirectory(tests)`, with no option gating it, and
# tests/CMakeLists.txt line 1 is
# `find_package(Python3 COMPONENTS Interpreter REQUIRED)`. -DBUILD_TESTING=OFF
# does not help: that gates CTest's own machinery, not an unconditional
# add_subdirectory. Without python3 the configure step fails with
# "Could NOT find Python3 (missing: Python3_EXECUTABLE Interpreter)" before a
# single object is compiled.
#
# The same shape as rocjitsu's unconditional fuzz/ subdirectories: an upstream
# CMakeLists that builds more than the consumer asked for, where the only
# remedy from here is to satisfy it.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    liblz4-dev \
    libzstd-dev \
    python3 \
    zlib1g-dev

ARG SDXI_REPO=https://github.com/ROCm/rocm-systems.git
ARG SDXI_BRANCH=users/stebates/emulation-sdxi
# The head of the branch above. Carries no default on purpose -- images.yml is
# the only place a pin is written. See "Why the Dockerfiles have no pin
# defaults" in the README. An undefaulted ARG is empty rather than an error, so
# this asserts.
ARG SDXI_COMMIT
RUN : "${SDXI_COMMIT:?set from images.yml by ci-images-tool.py; pass --build-arg SDXI_COMMIT=... for a bare docker build}"

# Optional, and empty by default: build against a libvfio-user of our choosing
# instead of the one emulation/sdxi/cmake/SdxiVfioUser.cmake pins
# (nutanix/libvfio-user at v0.8).
#
# Named _override_ and deliberately *not* the shared libvfio_user_repo /
# libvfio_user_commit, for the same reason ubuntu-rocm-rocjitsu and
# ubuntu-spdk-libvfio-user use that name: those vars always hold a real
# upstream SHA, so reusing them here would silently repoint every default build
# off the ref upstream chose. An override has to be asked for by name.
#
# Both or neither: a commit with no repo has nothing to fetch it from, and a
# repo with no commit would track a force-pushed branch.
ARG LIBVFIO_USER_REPO=
ARG LIBVFIO_USER_COMMIT=

WORKDIR /build

# Folded into one RUN rather than given a layer of its own: a separate layer
# would invalidate everything below it on the default path too, where these
# ARGs are empty and nothing is fetched. Same shape as ubuntu-rocm-rocjitsu.
#
# A real `git init` + fetch rather than a tarball, because
# emulation/sdxi/cmake/SdxiGitInfo.cmake shells out to git to stamp
# GIT_SHA_FULL/GIT_SHA_SHORT into the binary. It degrades to the literal
# "unknown" when git says nothing, which would make `rocm-sdxi -V` useless for
# telling two builds apart.
RUN git init /build/rocm-systems && \
    git -C /build/rocm-systems remote add origin "${SDXI_REPO}" && \
    git -C /build/rocm-systems fetch --depth 1 origin "${SDXI_COMMIT}" && \
    git -C /build/rocm-systems checkout FETCH_HEAD && \
    git -C /build/rocm-systems rev-parse HEAD > /build/sdxi-commit.txt && \
    if [ -n "${LIBVFIO_USER_REPO}" ] && [ -n "${LIBVFIO_USER_COMMIT}" ]; then \
        git init /build/libvfio-user && \
        git -C /build/libvfio-user \
            fetch --depth 1 "${LIBVFIO_USER_REPO}" "${LIBVFIO_USER_COMMIT}" && \
        git -C /build/libvfio-user checkout FETCH_HEAD && \
        git -C /build/libvfio-user rev-parse HEAD \
            > /build/libvfio-user-commit.txt && \
        echo "${LIBVFIO_USER_REPO}" > /build/libvfio-user-source.txt; \
    else \
        echo sdxi-cmake > /build/libvfio-user-source.txt; \
    fi

# FETCHCONTENT_SOURCE_DIR_LIBVFIO-USER is CMake's documented per-dependency
# override: FetchContent upper-cases the declared name (`libvfio-user`) and
# consults this variable before downloading, so a non-empty value makes it use
# that tree and fetch nothing. The hyphen is legal in a CMake variable name.
# Empty is exactly equivalent to not passing the flag, which keeps the default
# path identical to what it would be without this hook.
#
# No -Werror toggle is passed. emulation/sdxi/cmake/SdxiCompilerOptions.cmake
# gates it behind an SDXI_WERROR option that defaults OFF, unlike rocjitsu's
# rj_configure_target() which hardcodes it -- so this image does not need the
# warning-demotion flags that one carries.
#
# This used to pass -I/build/vfu-shim, a directory holding one symlink named
# `vfio-user`, because src/*.c include the library as
# <vfio-user/libvfio-user.h> -- the layout `meson install` produces -- while
# cmake/SdxiVfioUser.cmake exposed the FetchContent checkout's flat include/
# as the interface directory. The two had never agreed, so the FetchContent
# path could not compile at all:
#
#   src/rocm_sdxi_server.c:28:10: fatal error:
#   vfio-user/libvfio-user.h: No such file or directory
#
# Upstream took the same fix at 8b8f6e2f: SdxiVfioUser.cmake now builds the
# shim itself, with file(CREATE_LINK ... SYMBOLIC) into its own binary dir,
# and points the PUBLIC include directory there. It runs after
# FetchContent_MakeAvailable, so the source dir is populated, and it reads
# ${libvfio-user_SOURCE_DIR} rather than a fixed path, so it follows a
# FETCHCONTENT_SOURCE_DIR override the same way ours did. Carrying both would
# mean two include paths resolving the same headers, so ours is gone.
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    cmake \
    -B /build/rocm-systems/build \
    -G Ninja \
    -S /build/rocm-systems/emulation/sdxi \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DFETCHCONTENT_BASE_DIR=/tmp/deps \
    "-DFETCHCONTENT_SOURCE_DIR_LIBVFIO-USER=${LIBVFIO_USER_COMMIT:+/build/libvfio-user}" \
    -DBUILD_TESTING=OFF && \
    cmake --build /build/rocm-systems/build --parallel "$(nproc)" && \
    cmake --install /build/rocm-systems/build && \
    ldconfig

# Prove the override actually took, because every way it can fail is silent: an
# ignored variable, a misspelled name or a stale cache would all fall back to
# downloading v0.8 and produce a green build of the wrong library. Asserted
# against the CMakeCache -- what cmake resolved -- not against the flag passed.
#
# `test ! -e` says FetchContent created no -src for THIS dependency; /tmp/deps
# exists either way because json-c lands there too.
RUN set -eu; \
    if [ -n "${LIBVFIO_USER_COMMIT}" ]; then \
        grep -q 'FETCHCONTENT_SOURCE_DIR_LIBVFIO-USER:.*=/build/libvfio-user' \
            /build/rocm-systems/build/CMakeCache.txt; \
        test ! -e /tmp/deps/libvfio-user-src; \
    else \
        test -d /tmp/deps/libvfio-user-src; \
    fi

# The guest-side payload, staged rather than built: these are kernel modules
# and a Python package, and there is no guest kernel here to build the first
# against. ubuntu-qcow2-gen's rocjitsu flavour fetches its own copy at the same
# pin -- images.yml requires the two to be equal -- so this copy is for an
# operator working against a running stack, and for reading what the pin
# actually contains without a checkout.
RUN set -eux; \
    install -d /usr/local/share/rocm-sdxi; \
    cp -a /build/rocm-systems/emulation/sdxi/drivers \
          /usr/local/share/rocm-sdxi/drivers; \
    cp -a /build/rocm-systems/emulation/sdxi/tools \
          /usr/local/share/rocm-sdxi/tools; \
    test -f /usr/local/share/rocm-sdxi/drivers/sdxi_char/sdxi_char.c; \
    test -f /usr/local/share/rocm-sdxi/tools/sdxi-cli/pyproject.toml

ENV SDXI_SOCKET_DIR=/run/rocm-sdxi

# Provenance, with the dependency tags read out of the cmake that pins them
# rather than restated here, so a bump upstream cannot leave this metadata
# lying about what the vfio-user transport was built against.
#
# read_pin walks the whole FetchContent_Declare block and takes its GIT_TAG
# rather than assuming the tag follows the URL on the next line -- the same
# order-independent, comment-proof reader ubuntu-rocm-rocjitsu uses, and for
# the same reason: the naive version printed the first word of whatever
# followed.
#
# libvfio_user_upstream_tag is what the tree declares and libvfio_user_tag is
# what was really built; libvfio_user_source says which of the two supplied it.
# Without that split, an override build's own provenance would lie.
RUN set -eu; \
    src=/build/rocm-systems/emulation/sdxi; \
    cmake_pins="${src}/cmake/SdxiVfioUser.cmake"; \
    read_pin() { awk -v url="$1" '/FetchContent_Declare\(/{inblk=1;tag="";hit=0;next} inblk{ if(index($0,url)) hit=1; if($1=="GIT_TAG") tag=$2; if($0 ~ /^[[:space:]]*\)/){ if(hit && tag!=""){print tag; exit} inblk=0 } }' "$2"; }; \
    libvfio_user_tag="$(read_pin libvfio-user.git "${cmake_pins}")"; \
    json_c_tag="$(read_pin json-c.git "${cmake_pins}")"; \
    test -n "${libvfio_user_tag}"; \
    test -n "${json_c_tag}"; \
    libvfio_user_upstream_tag="${libvfio_user_tag}"; \
    if [ -s /build/libvfio-user-commit.txt ]; then \
        libvfio_user_tag="$(cat /build/libvfio-user-commit.txt)"; \
    fi; \
    cp /build/sdxi-commit.txt /usr/local/share/rocm-sdxi-commit.txt; \
    printf '{\n\
  "sdxi_repo": "%s",\n\
  "sdxi_branch": "%s",\n\
  "sdxi_commit": "%s",\n\
  "local_patches": [],\n\
  "libvfio_user_source": "%s",\n\
  "libvfio_user_upstream_tag": "%s",\n\
  "libvfio_user_tag": "%s",\n\
  "json_c_tag": "%s",\n\
  "guest_payload": "/usr/local/share/rocm-sdxi",\n\
  "guest_modules": ["sdxi_char"],\n\
  "socket_dir": "%s"\n\
}\n' \
        "${SDXI_REPO}" \
        "${SDXI_BRANCH}" \
        "$(cat /build/sdxi-commit.txt)" \
        "$(cat /build/libvfio-user-source.txt)" \
        "${libvfio_user_upstream_tag}" \
        "${libvfio_user_tag}" \
        "${json_c_tag}" \
        "${SDXI_SOCKET_DIR}" \
        > /usr/local/share/rocm-sdxi-build.json; \
    cat /usr/local/share/rocm-sdxi-build.json; \
    mkdir -p "${SDXI_SOCKET_DIR}"

# Prove the vfio-user front end reaches a usable device, not just that it
# linked. Three things about this probe are load-bearing and were all read out
# of src/rocm_sdxi_server.c rather than assumed:
#
#   * -v is required. main() sets the level to WARN when verbosity is 0, and
#     the readiness line is INFO, so a probe without -v waits forever for a
#     line that is never printed. This is the whole reason the flag is here.
#   * The line goes to stderr, like every other log line -- sdxi_log() writes
#     to stderr exclusively, and the only stdout write in the program is the -V
#     handler. So 2>&1, not >.
#   * The server never exits on its own once serving: with
#     LIBVFIO_USER_FLAG_ATTACH_NB and no client, vfu_attach_ctx returns EAGAIN
#     and it spins at 100 us. So the verdict has to be latched inside the loop
#     and the process killed, exactly as ubuntu-rocm-rocjitsu does -- and for
#     the same second reason, that libvfio-user unlinks its socket on teardown,
#     so re-testing the socket afterwards would always fail.
#
# A setup failure prints regardless of verbosity (ERROR is level 0, never
# suppressed) and exits 1, so the kill -0 arm catches it with the cause in the
# log we cat below.
# hadolint ignore=DL3001
RUN rocm-sdxi --socket /tmp/probe.sock -v > /tmp/probe.log 2>&1 & \
    probe_pid=$!; \
    served=0; \
    i=0; \
    while [ "$i" -lt 150 ]; do \
        if [ -S /tmp/probe.sock ] && \
           grep -q 'listening on socket' /tmp/probe.log; then \
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
        echo "rocm-sdxi did not serve a vfio-user device" >&2; \
        exit 1; \
    fi; \
    rm -f /tmp/probe.log

# The version handler is the one thing that writes to stdout, and it is how a
# consumer tells two builds of the same tag apart -- so assert it says
# something other than the "unknown" SdxiGitInfo.cmake falls back to when git
# is unavailable. A tarball fetch instead of a git one would pass every check
# above and fail this.
#
# case rather than a grep pipeline: `--version` prints exactly one line, and
# `... | grep -qv` on one line is a double negative that reads as the opposite
# of what it does. It also keeps this RUN free of pipes, so the shell's exit
# status is the command's own.
RUN set -eux; \
    ver="$(rocm-sdxi --version)"; \
    echo "${ver}"; \
    case "${ver}" in \
        *"git unknown"*) \
            echo "rocm-sdxi has no git stamp: SdxiGitInfo.cmake found no" \
                 ".git, so this was not built from a git checkout" >&2; \
            exit 1;; \
    esac; \
    help="$(rocm-sdxi --help 2>&1 || true)"; \
    case "${help}" in \
        *--socket*) : ;; \
        *) echo "rocm-sdxi --help does not mention --socket" >&2; exit 1;; \
    esac

RUN rm -rf /build/rocm-systems /build/libvfio-user /tmp/deps

ENV PATH=/usr/local/bin:${PATH}

# sh -c so SDXI_SOCKET_DIR expands; exec so rocm-sdxi still ends up as PID 1 and
# libvfio-user gets the SIGTERM that unlinks its socket on teardown. -v so the
# readiness line reaches the container log -- without it a healthy server is
# completely silent, which reads as a hang.
CMD ["sh", "-c", \
     "exec rocm-sdxi --socket \"${SDXI_SOCKET_DIR}/rocm-sdxi.sock\" -v"]
