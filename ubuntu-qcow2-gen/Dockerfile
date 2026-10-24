# syntax=docker/dockerfile:1-labs
# check=skip=SecretsUsedInArgOrEnv
#
# PASSWORD is the guest VM's console login, not a credential for anything
# outside the qcow2.  It is published in /output/vm-info.json by design, so a
# secret mount would hide it from the build history and then ship it in the
# payload anyway.  images.yml marks it secret: true, which keeps it out of
# `build-args` output and therefore out of CI logs.
#
# Guest qcow2 generator.  One parameterised Dockerfile, one flavour per
# images.yml variant: the build boots a real VM with "qemu-tool gen-vm",
# provisions it with cloud-init packages and (optionally) an Ansible playbook,
# and exports the result FROM scratch so consumers pull a bare payload rather
# than the multi-GB QEMU toolchain that produced it.

# The builder/runner toolchain: QEMU, qemu-tool, ansible-core, libvfio-user.
ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-qemu-libvfio-user:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive

ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG FLAVOUR=basic
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=resolute
ARG ARCH=amd64
ARG VM_SIZE=512
ARG VM_VCPUS=4
ARG VM_VMEM=4096
ARG VM_PACKAGES=base.txt
ARG VM_PLAYBOOK=
# A second playbook, run against the provisioned guest rather than during
# gen-vm; see the layer's note in build-vm.sh.
ARG POST_PLAYBOOK=
ARG KERNEL_REF=
ARG AMDGPU_DRIVER_VERSION=latest
ARG ROCM_PATH=
ARG ROCM_VERSION=
ARG RDMA_CORE_VERSION=
ARG FIO_COMMIT=
# Whose provision script and assets to use (empty: this flavour's own), and
# the trim/<file> that takes things back out afterwards (empty: none).
ARG PROVISION_FLAVOUR=
ARG TRIM=
ARG CACHE_BUST=

WORKDIR /build

# The base image installs qemu-tool from its own qemu-minimal checkout and then
# deletes it.  Re-clone here: the Ansible playbooks, inventory and
# requirements.yml live in the tree, not the wheel, and --ansible-playbook
# resolves them relative to the playbook path.  Kept in its own layer so it
# caches independently of the VM build.
RUN set -eux; \
    if [ -z "${QEMU_MINIMAL_REPO}" ] || [ "${QEMU_MINIMAL_REPO}" = "none" ]; then \
        echo "Error: QEMU_MINIMAL_REPO is required to build a guest image"; \
        exit 1; \
    fi; \
    git clone "${QEMU_MINIMAL_REPO}" /build/qemu-minimal; \
    cd /build/qemu-minimal; \
    if [ -n "${QEMU_MINIMAL_COMMIT}" ]; then \
        git checkout "${QEMU_MINIMAL_COMMIT}"; \
    fi; \
    git rev-parse HEAD > /build/qemu-minimal-commit.txt

# Reinstall qemu-tool from this checkout so the CLI and the ansible/ tree it
# drives always come from the same commit, whatever the base image pinned.
RUN python3 -m venv /opt/qemu-tool --clear && \
    /opt/qemu-tool/bin/pip install --no-cache-dir /build/qemu-minimal/qemu && \
    ln -sf /opt/qemu-tool/bin/qemu-tool /usr/local/bin/qemu-tool && \
    qemu-tool --version

# An apt cache on the builder, for the guest's own downloads.
#
# INCOMPLETE: this is plumbing that does not yet save anything. It is kept
# because the hard half works and the remaining half is known; see the long
# note in build-vm.sh at the apt-proxy injection for the measurements. In
# short, cloud-init does the archive install inside gen-vm before any proxy
# exists, and the acng store is not retaining what does go through it, so
# 68158648 counted 1039 direct fetches against 17 remapped ones. Do not cite
# this as a saving until both are closed.
#
# The intent: every boot of every flavour re-fetches the same packages -- the
# Ubuntu archive for the toolchain, repo.radeon.com for amdgpu-dkms (~31 MB of
# .debs before dependencies) and stable.repo.amd.com for ROCm (several hundred
# MB). Those are bytes, wall-clock and -- since archive.ubuntu.com refusing
# connections mid-build is a recurring flake here -- a source of spurious
# failures that read as "requested packages missing from guest".
#
# apt-cacher-ng runs on the builder, and the guest reaches it at 10.0.2.2 on a
# per-flavour port, which is slirp's gateway address for the host. Its store is
# a BuildKit cache mount, so it is meant to survive between builds on the same
# node.
#
# The remaps are the part that demonstrably works: acng tunnels an https://
# request through untouched, so the guest is pointed at an http:// URL with a
# remap key instead and acng fetches the real thing over TLS upstream.
# Packages do arrive that way -- "Get:1 http://radeon/amdgpu/..." in any guest
# log. The repository signature is still checked by apt in the guest, so the
# plain-http hop to a cache on the same machine costs nothing in trust.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends apt-cacher-ng

COPY ubuntu-qcow2-gen/apt-cacher-ng.conf \
     /etc/apt-cacher-ng/zz-ci-images.conf

# One keypair per flavour, generated here rather than inherited: the base image
# is toolchain-only and ships neither a guest nor a key.  The rm still runs
# because the final stage copies /output wholesale -- anything that ever appears
# there is published as this flavour's payload -- and because a leftover
# /root/.ssh would make ssh-keygen prompt to overwrite, which fails the build
# rather than silently reusing a key from another flavour.
RUN rm -rf /output /root/.ssh && \
    mkdir -p /output /root/.ssh && \
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q

COPY ubuntu-qcow2-gen/build-vm.sh /usr/local/bin/build-vm
COPY ubuntu-qcow2-gen/probe-guest.sh /usr/local/bin/probe-guest
RUN chmod +x /usr/local/bin/build-vm /usr/local/bin/probe-guest

# Every knob the guest build reads, declared once and promoted to ENV.
#
# ARG values do not cross a FROM, and the build is now four stages: repeating
# this block four times is how that goes wrong quietly, because an ARG missing
# from one copy does not fail, it silently takes its default. build-vm.sh reads
# all of these out of the environment already, so ENV is both the smaller
# change and the one a later stage inherits for free.
#
# PASSWORD among them: it is the guest's console login, already published in
# vm-info.json by design and already in the build history as an ARG, and the
# final stage is FROM scratch with nothing but a COPY -- so it reaches no
# published image config. See the note at the top of this file.
FROM base AS config
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG FLAVOUR=basic
ARG USERNAME=batesste
ARG VM_NAME=
ARG PASSWORD=changeme
ARG RELEASE=resolute
ARG ARCH=amd64
ARG VM_SIZE=512
ARG VM_VCPUS=4
ARG VM_VMEM=4096
ARG VM_PACKAGES=base.txt
ARG VM_PLAYBOOK=
# A second playbook, run against the provisioned guest rather than during
# gen-vm; see the layer's note in build-vm.sh.
ARG POST_PLAYBOOK=
ARG KERNEL_REF=
ARG AMDGPU_DRIVER_VERSION=latest
ARG ROCM_PATH=
ARG ROCM_VERSION=
ARG RDMA_CORE_VERSION=
ARG FIO_COMMIT=
# Whose provision script and assets to use (empty: this flavour's own), and
# the trim/<file> that takes things back out afterwards (empty: none).
ARG PROVISION_FLAVOUR=
ARG TRIM=
ARG CACHE_BUST=
# The host port probe-guest forwards the guest's SSH to, and the one thing in
# this build that is not private to it: a --security=insecure step shares the
# host network namespace, so two flavours building at once both try to bind it
# and the second dies with "Could not set up host forwarding rule". That never
# happened while the flavours were built one per CI job or one per `docker
# buildx build`; bake builds all four at once on one machine, which is the
# point of it. Each flavour therefore pins its own port in images.yml.
ARG PROBE_SSH_PORT=2222
ENV QEMU_MINIMAL_REPO=${QEMU_MINIMAL_REPO} \
    QEMU_MINIMAL_COMMIT=${QEMU_MINIMAL_COMMIT} \
    FLAVOUR=${FLAVOUR} \
    USERNAME=${USERNAME} \
    VM_NAME=${VM_NAME} \
    PASSWORD=${PASSWORD} \
    RELEASE=${RELEASE} \
    ARCH=${ARCH} \
    VM_SIZE=${VM_SIZE} \
    VM_VCPUS=${VM_VCPUS} \
    VM_VMEM=${VM_VMEM} \
    VM_PACKAGES=${VM_PACKAGES} \
    VM_PLAYBOOK=${VM_PLAYBOOK} \
    POST_PLAYBOOK=${POST_PLAYBOOK} \
    KERNEL_REF=${KERNEL_REF} \
    AMDGPU_DRIVER_VERSION=${AMDGPU_DRIVER_VERSION} \
    ROCM_PATH=${ROCM_PATH} \
    ROCM_VERSION=${ROCM_VERSION} \
    RDMA_CORE_VERSION=${RDMA_CORE_VERSION} \
    FIO_COMMIT=${FIO_COMMIT} \
    PROVISION_FLAVOUR=${PROVISION_FLAVOUR} \
    TRIM=${TRIM} \
    CACHE_BUST=${CACHE_BUST} \
    PROBE_SSH_PORT=${PROBE_SSH_PORT}

# --security=insecure is what lets these steps create and open /dev/kvm, so this
# needs "buildx build --allow security.insecure" against a builder started with
# --allow-insecure-entitlement=security.insecure.  There is no TCG fallback:
# emulation is ~10x slower, so a missing /dev/kvm fails the build.
#
# The bind mount exposes common/ from the build context: pre-downloaded cloud
# images land where "qemu-tool gen-vm" looks, and the AMD root CA (gitignored,
# absent in CI) is injected into the guest trust store when present.
#
# Four steps rather than one, one per BUILD_PHASE of build-vm.
#
# This was a single RUN covering the whole pipeline, which meant a one-line
# edit to a checks file -- seven seconds of actual work -- rebuilt the twenty
# minutes of gen-vm, kernel install, ROCm and DKMS ahead of it.  The boundaries
# are the points where the inputs change, and each phase's COPY sits
# immediately above its own RUN rather than in the shared base, which is what
# makes the invalidation land on the right step: touching checks/ must not
# reach back past the trim.
#
# The cost is that every phase snapshots the guest qcow2 -- several GB a layer
# on the fat flavours.  That is affordable against the builder's own state
# volume, which is where the Slurm path keeps its cache and is node-local; it
# is also why pushing all of it down an NFS CACHE_LOCAL is still not the
# default.  See docker-bake.hcl.

# ── phase: stage ── gen-vm, the harden boot, the mainline kernel.
# Reads the release, the package manifest and KERNEL_REF.
#
# Also where a derived flavour adopts its parent instead of building anything.
# `parentguest` is a named build context that bake always defines: the fat
# flavour's target for a derived flavour, and an empty directory otherwise. A
# bind mount rather than a COPY precisely so the "otherwise" case is legal --
# COPY --from against a context with no /output in it is an error, while a bind
# mount of a directory with nothing in it is simply an empty /parent, which is
# what build-vm.sh tests for.
FROM config AS staged
# Redeclared purely so ${FLAVOUR} expands in the cache-mount id below: mount
# options are resolved from build args, and an ARG does not cross a FROM. The
# ENV of the same name inherited from `config` still wins inside the RUN, so
# this changes nothing the script sees.
#
# A per-flavour id is what keeps the five guest builds concurrent. One shared
# id with sharing=locked serialises every step that holds it, and measured on
# 68152691 that cost 2269s of the 4099s spent in guest steps: `ubuntu-qcow2-gen
# provisioned` blocked for 470.4s to do 0.1s of work, and `ernic-rocjitsu
# staged` blocked 453.4s. Bake exists to build these at once; a shared lock
# undoes it. With per-flavour ids, 68153192 measured 1.5s of blocking in total.
#
# The cost is that each flavour now keeps its own acng store rather than
# sharing one: the Ubuntu archive packages they have in common are fetched
# once per flavour instead of once, and the cache is five copies on disk.
# That is not recoverable while each step runs its own daemon -- five acng
# processes over one cache directory is not something acng supports, and
# BuildKit gives no way to run one daemon across steps -- and 68153192 says
# the parallelism is worth far more than the sharing was.
ARG FLAVOUR=basic
# Per-flavour cloud-init package manifests.  Copied whole so a flavour is
# packages/<name>.txt plus an optional provision/<name>.sh plus checks/<name>.sh
# plus an images.yml variant, with no Dockerfile change.
COPY ubuntu-qcow2-gen/packages/ /build/packages/
# hadolint ignore=DL3059
RUN --security=insecure \
    --mount=type=bind,source=common,target=/ctx/common \
    --mount=type=cache,id=acng-${FLAVOUR},target=/var/cache/apt-cacher-ng,sharing=locked \
    --mount=type=bind,from=parentguest,target=/parent \
    BUILD_PHASE=stage build-vm

# ── phase: provision ── provision/<flavour>.sh and the post-provision playbook.
# The expensive half: ROCm, the amdgpu DKMS build, the SRQ playbook.
FROM staged AS provisioned
# As above: for the cache-mount id only.
ARG FLAVOUR=basic
COPY ubuntu-qcow2-gen/provision/ /build/provision/

# Files a provision script needs *inside* the guest -- patches, generators --
# rather than on the builder.  build-vm.sh copies assets/<flavour> to
# /tmp/payload in the provisioning boot when it exists, using the same
# primitive the mainline kernel .debs already travel by.
COPY ubuntu-qcow2-gen/assets/ /build/assets/

# assets/shared/ is not a flavour -- build-vm.sh never looks for it. Its
# contents are grafted onto the payload of each flavour that wants them, so the
# amdgpu-probe helper and the RAS patch exist once in the repo and cannot drift
# between the two guests that build the same driver. See assets/shared/README.md.
#
# One COPY per source: a directory source contributes its *contents*, so
# "patches/" and "patches/" in one multi-source COPY would both land as
# amdgpu/ at the top of the payload rather than under patches/.
COPY ubuntu-qcow2-gen/assets/shared/amdgpu-probe /build/assets/rocjitsu/amdgpu-probe
COPY ubuntu-qcow2-gen/assets/shared/amdgpu-probe-motd \
     /build/assets/rocjitsu/amdgpu-probe-motd
COPY ubuntu-qcow2-gen/assets/shared/patches/ /build/assets/rocjitsu/patches/
COPY ubuntu-qcow2-gen/assets/shared/amdgpu-probe \
     /build/assets/ernic-rocjitsu/amdgpu-probe
COPY ubuntu-qcow2-gen/assets/shared/amdgpu-probe-motd \
     /build/assets/ernic-rocjitsu/amdgpu-probe-motd
COPY ubuntu-qcow2-gen/assets/shared/patches/ /build/assets/ernic-rocjitsu/patches/

# The firmware generator, wired in here rather than vendored a second time:
# ubuntu-rocm-rocjitsu owns it, the ernic-rocjitsu guest runs it (with
# --generation, since no rocjitsu config exists in a guest), and one copy in
# the repo means the fixtures a guest carries cannot drift from the ones that
# image's own self-test exercises.
COPY ubuntu-rocm-rocjitsu/vfio-guest-firmware.py \
     /build/assets/ernic-rocjitsu/vfio-guest-firmware.py
# /ccache-guest is the compiler cache for the amdgpu DKMS build *inside* the
# guest.  probe-guest carries it in over SSH and back out again, so a rebuild
# whose driver source and kernel headers have not moved does not recompile
# ~210s of C.  Only this phase compiles anything, so only this phase mounts it.
#
# sharing=shared, and deliberately one cache for all the flavours rather than
# one each: rocjitsu and ernic-rocjitsu compile the same amdgpu source, so a
# shared cache is where the hits come from.  ccache is built for concurrent
# access -- it locks per entry -- so two guests writing at once is the case it
# is designed for, not a hazard.
#
# This was sharing=locked out of over-caution, copied from the container ccache
# mounts, and it serialised the provision phases: see the note on the staged
# stage above.
# hadolint ignore=DL3059
RUN --security=insecure \
    --mount=type=bind,source=common,target=/ctx/common \
    --mount=type=cache,id=acng-${FLAVOUR},target=/var/cache/apt-cacher-ng,sharing=locked \
    --mount=type=cache,target=/ccache-guest,sharing=shared \
    BUILD_PHASE=provision build-vm

# ── phase: trim ── trim/<file> and the compacting convert.
# A no-op for a flavour that ships what it provisioned.
FROM provisioned AS trimmed
# The trim layer: scripts that take things back out of a provisioned guest, for
# a flavour that is another flavour's image minus what a runtime consumer
# cannot use. Named by the flavour's TRIM var, so adding one is a file here.
COPY ubuntu-qcow2-gen/trim/ /build/trim/
# hadolint ignore=DL3059
RUN --security=insecure \
    --mount=type=bind,source=common,target=/ctx/common \
    BUILD_PHASE=trim build-vm

# ── phase: verify ── the verification boot, the checks and vm-info.json.
# The cheapest phase and the most often edited, which is the point of the split.
FROM trimmed AS built
COPY ubuntu-qcow2-gen/checks/ /build/checks/
# hadolint ignore=DL3059
RUN --security=insecure \
    --mount=type=bind,source=common,target=/ctx/common \
    BUILD_PHASE=verify build-vm

# A pure payload: nothing to run, nothing to patch, no CVE surface.  Consume it
# with "docker create" + "docker cp", or with COPY --from in another build.
FROM scratch
COPY --from=built /output/ /output/
# There is no runtime here, and none is wanted -- but "docker create" refuses an
# image with no command at all, and that is how the payload gets extracted.
CMD ["/output/vm-info.json"]
