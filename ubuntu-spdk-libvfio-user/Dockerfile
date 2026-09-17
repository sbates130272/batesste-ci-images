# SPDK's NVMe-oF target speaking vfio-user: an NVMe controller emulated outside
# the VMM and offered to a guest over a Unix socket, the storage counterpart to
# ubuntu-rocm-ernic's NIC and ubuntu-rocm-rocjitsu's GPU.
#
# This one does NOT layer on ubuntu-libvfio-user. SPDK's vfio-user target only
# builds against libvfio-user's own spdk branch, which is what the SPDK
# submodule carries; this repo's shared libvfio_user_commit tracks the
# qemu-project tree that QEMU and rocm-ernic want. Pairing them would break on
# the next bump of either, so SPDK uses its submodule and the resolved SHA is
# recorded below for provenance instead of being pinned from images.yml.
ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# SPDK's build deps beyond the base image, plus the Python modules scripts/rpc.py
# imports at run time. scripts/pkgdep.sh below fills in whatever else the pinned
# tree wants; this list is what the build is known to need, so a pkgdep.sh that
# changes upstream cannot silently drop a requirement.
#
# Deliberately absent: librados-dev/librbd-dev. Without them configure leaves
# CONFIG_RBD off, and module/kvdev/Makefile gates its rados backend on exactly
# that while keeping `mem` unconditional -- so the KV command set still works,
# backed by memory, and no Ceph enters the image. See README.md.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    libaio-dev \
    libcmocka-dev \
    libcunit1-dev \
    libfuse3-dev \
    libjson-c-dev \
    libncurses-dev \
    libnuma-dev \
    libssl-dev \
    meson \
    python3 \
    python3-configshell-fb \
    python3-jinja2 \
    python3-pyelftools \
    python3-tabulate \
    uuid-dev

# The fork carrying the target-side Key Value command set: the kvdev layer,
# module/kvdev/{mem,rados} and nvmf_subsystem_add_kv_ns. Upstream SPDK v26.05
# added KV to the *initiator* only (include/spdk/nvme_kv.h), so there is no
# upstream ref that can serve a KV namespace to a guest. Move this back to
# spdk/spdk once that work lands; see images.yml.
ARG SPDK_REPO=https://github.com/mmgaggle/spdk.git
ARG SPDK_BRANCH=rados-nkv
ARG SPDK_COMMIT=18d1d8dab4f2020e10349009e69f94d47de100f9
ARG CACHE_BUST=

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/spdk_cache_bust.txt

ENV SPDK_DIR=/opt/spdk

# --init and not --init --recursive: SPDK's direct submodules (dpdk, intel-ipsec-mb,
# isa-l, isa-l-crypto, libvfio-user, ocf) are all the build needs, and recursing
# into dpdk's own drags in trees nothing here compiles.
RUN git clone --branch "${SPDK_BRANCH}" "${SPDK_REPO}" "${SPDK_DIR}" && \
    git -C "${SPDK_DIR}" checkout "${SPDK_COMMIT}" && \
    git -C "${SPDK_DIR}" submodule update --init && \
    git -C "${SPDK_DIR}" rev-parse HEAD > /build/spdk-commit.txt && \
    git -C "${SPDK_DIR}/libvfio-user" rev-parse HEAD \
        > /build/libvfio-user-commit.txt

# pkgdep.sh is upstream's own dependency list and is allowed to fail: it tries
# to install packages that do not exist on every release, and the explicit list
# above is what the build actually depends on. A genuinely missing dependency
# surfaces as a compile error in the next step, which is the legible failure.
# hadolint ignore=DL3003
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    cd "${SPDK_DIR}" && ./scripts/pkgdep.sh || true

# --without-nvme-cuse: the CUSE character devices need /dev/fuse and a
# privileged container, and nothing here drives an NVMe controller from the
# host side. --with-vfio-user is the whole point of the image.
#
# --target-arch: configure defaults to `native`, which puts -march=native into
# SPDK's own CFLAGS and -Dcpu_instruction_set=native into DPDK's meson. That
# bakes the *builder's* CPU into the binary, so the image only runs on a host
# at least as capable -- and a layer cache shared between two machines turns
# that into a SIGILL at startup rather than a build error. corei7 is the value
# DPDK's own `generic` resolves to on x86 (dpdk/config/meson.build), so it is
# the vendor's baseline rather than a number picked here; `generic` itself
# cannot be used because gcc rejects it as a -march.
#
# PATH rather than CC="ccache gcc": SPDK's makefiles re-exec the compiler by
# name, so a recorded "ccache gcc" is not preserved the way QEMU's configure
# preserves it.
# hadolint ignore=DL3003
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    cd "${SPDK_DIR}" && \
    PATH=/usr/lib/ccache:${PATH} ./configure \
        --with-vfio-user \
        --without-nvme-cuse \
        --target-arch=corei7 && \
    PATH=/usr/lib/ccache:${PATH} make -j"$(nproc)" && \
    test -x "${SPDK_DIR}/build/bin/nvmf_tgt"

# No `make install`: SPDK installs its libraries and headers but not nvmf_tgt,
# and the RPC scripts expect to sit inside the tree. Symlink what callers need
# onto PATH and leave the tree where it is.
RUN ln -sf "${SPDK_DIR}/build/bin/nvmf_tgt" /usr/local/bin/nvmf_tgt && \
    ln -sf "${SPDK_DIR}/scripts/rpc.py" /usr/local/bin/rpc.py && \
    cp /build/spdk-commit.txt /usr/local/share/spdk-commit.txt && \
    cp /build/libvfio-user-commit.txt \
        /usr/local/share/libvfio-user-commit.txt && \
    printf '{\n\
  "spdk_repo": "%s",\n\
  "spdk_branch": "%s",\n\
  "spdk_commit": "%s",\n\
  "libvfio_user_commit": "%s",\n\
  "libvfio_user_source": "spdk-submodule",\n\
  "configure_flags": ["--with-vfio-user", "--without-nvme-cuse",\n\
                      "--target-arch=corei7"],\n\
  "rbd_enabled": false,\n\
  "kv_backends": ["mem"]\n\
}\n' \
        "${SPDK_REPO}" \
        "${SPDK_BRANCH}" \
        "$(cat /build/spdk-commit.txt)" \
        "$(cat /build/libvfio-user-commit.txt)" \
        > /usr/local/share/spdk-build.json

ENV NVME_NAMESPACES="lba:malloc:512M,kv:mem" \
    NQN=nqn.2019-07.io.spdk:cnode1 \
    VFIO_USER_SOCKET_DIR=/tmp/vfio-sockets/nvme \
    SPDK_SERIAL=SPDKVFU01 \
    SPDK_CPUMASK=0x1 \
    SPDK_HUGE=auto \
    SPDK_MEM_SIZE=1024

COPY ubuntu-spdk-libvfio-user/entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

# rpc.py finds its spdk package relative to __file__, which resolves to
# /usr/local/bin through the symlink above -- so `docker exec <c> rpc.py ...`
# dies on ModuleNotFoundError without this. The entrypoint invokes the real
# path and is unaffected either way.
ENV PATH=/usr/local/bin:${PATH} \
    PYTHONPATH=/opt/spdk/python

# Prove the target actually serves a controller, rather than just that it
# linked: a transport, a subsystem, one memory-backed LBA namespace, one
# file-backed LBA namespace and one KV namespace, then assert the vfio-user
# socket exists. This is the same "fail at build time, not deploy time" stance
# the rocjitsu image takes, and it is the step that catches a fork whose RPC
# names have moved under us.
#
# No hugepages exist inside a BuildKit step, so this exercises the --no-huge
# fallback path specifically; SPDK_HUGE=auto would pick it anyway. The rpc.py
# --help first is not redundant with the entrypoint's own RPC calls: it is the
# only thing that exercises the symlinked spelling callers use.
# hadolint ignore=DL3001
RUN set -eux; \
    rpc.py --help > /dev/null; \
    NVME_NAMESPACES='lba:malloc:64M,lba:aio:/tmp/probe-ns.img,kv:mem' \
    VFIO_USER_SOCKET_DIR=/tmp/probe-sockets \
    SPDK_HUGE=off \
    SPDK_MEM_SIZE=512 \
    /build/entrypoint.sh --probe; \
    rm -rf /tmp/probe-ns.img /tmp/probe-sockets

ENTRYPOINT ["/build/entrypoint.sh"]
