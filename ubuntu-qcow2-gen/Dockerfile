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
ARG KERNEL_REF=
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

# Per-flavour cloud-init package manifests and post-build assertions.  Copied
# whole so a flavour is packages/<name>.txt plus checks/<name>.sh plus an
# images.yml variant, with no Dockerfile change.
COPY ubuntu-qcow2-gen/packages/ /build/packages/
COPY ubuntu-qcow2-gen/checks/ /build/checks/

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

# --security=insecure is what lets the step create and open /dev/kvm, so this
# needs "buildx build --allow security.insecure" against a builder started with
# --allow-insecure-entitlement=security.insecure.  There is no TCG fallback:
# emulation is ~10x slower, so a missing /dev/kvm fails the build.
#
# The bind mount exposes common/ from the build context: pre-downloaded cloud
# images land where "qemu-tool gen-vm" looks, and the AMD root CA (gitignored,
# absent in CI) is injected into the guest trust store when present.
FROM base AS built
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
ARG KERNEL_REF=
ARG CACHE_BUST=
# hadolint ignore=DL3059
RUN --security=insecure \
    --mount=type=bind,source=common,target=/ctx/common \
    build-vm

# A pure payload: nothing to run, nothing to patch, no CVE surface.  Consume it
# with "docker create" + "docker cp", or with COPY --from in another build.
FROM scratch
COPY --from=built /output/ /output/
# There is no runtime here, and none is wanted -- but "docker create" refuses an
# image with no command at all, and that is how the payload gets extracted.
CMD ["/output/vm-info.json"]
