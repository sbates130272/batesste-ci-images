# syntax=docker/dockerfile:1-labs
#
# The QEMU builder/runner toolchain: QEMU with libvfio-user and slirp, the
# qemu-tool CLI, ansible-core and the Docker CLI.  It builds no guest image of
# its own -- that is ubuntu-qcow2-gen's job, one repository per flavour -- so
# /output ships empty and a guest is supplied at run time:
#
#   cid=$(docker create sbates130272/batesste-ci-images-ubuntu-qcow2-gen:latest)
#   docker cp "$cid:/output/." ./vm && docker rm "$cid"
#   docker run -v "$PWD/vm:/output" ...   # rw: QEMU opens the disk rw
#
# entrypoint.sh also accepts a guest under /build/qemu-minimal/images.

# libvfio-user is already built and installed under /usr/local by the base
# image, which pins the same SHA this image used to build for itself.
ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-libvfio-user:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS base

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for QEMU beyond those in the base image
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    jq \
    python3 \
    python3-venv \
    libpixman-1-dev \
    libslirp-dev

# Accept QEMU tags or commit SHAs
ARG QEMU_REPO=https://gitlab.com/qemu-project/qemu.git
ARG QEMU_COMMIT=v11.1.1

# The qemu-minimal checkout the qemu-tool CLI is installed from.  Guest
# provisioning parameters (release, size, packages, playbook, kernel) are not
# here: they belong to ubuntu-qcow2-gen, which builds the guests.
ARG QEMU_MINIMAL_REPO=
ARG QEMU_MINIMAL_COMMIT=
ARG CACHE_BUST=

WORKDIR /build

# Clone QEMU: shallow clone for tags, treeless for SHAs
RUN if echo "${QEMU_COMMIT}" | \
        grep -qE '^[0-9a-f]{7,40}$'; then \
        git clone --filter=blob:none \
            "${QEMU_REPO}" \
            /build/qemu && \
        cd /build/qemu && \
        git checkout "${QEMU_COMMIT}"; \
    else \
        git clone --depth 1 \
            --branch "${QEMU_COMMIT}" \
            "${QEMU_REPO}" \
            /build/qemu; \
    fi && \
    cd /build/qemu && \
    git rev-parse HEAD > /build/qemu-commit.txt

# Build QEMU with slirp networking support
WORKDIR /build/qemu
# --cc/--cxx rather than PATH=/usr/lib/ccache: QEMU's configure records the
# compiler it was handed into the generated ninja files, and a bare "gcc" there
# resolves without ccache when the build re-execs.
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    ./configure --target-list=x86_64-softmmu \
                --enable-slirp \
                --cc="ccache gcc" \
                --cxx="ccache g++" \
                --prefix=/opt/qemu && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /build/qemu

# Install cloud-init utilities for VM creation
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    cloud-image-utils \
    qemu-utils \
    wget \
    openssh-client

# Docker CLI (no daemon): qemu-tool's "compose" subcommand shells out to
# "docker compose", and CI jobs running inside this image drive the host's
# daemon over a bind-mounted /var/run/docker.sock.  Ubuntu's docker.io package
# would pull in the engine, so take the CLI-only packages from Docker's own
# repository instead.
# apt reads an ASCII-armoured key directly from a .asc, so there is no need to
# pull gnupg in just to dearmor it.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    . /etc/os-release && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL -o /etc/apt/keyrings/docker.asc \
        https://download.docker.com/linux/ubuntu/gpg && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
        "${VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin && \
    docker --version && \
    docker compose version

# Python packaging tooling. setuptools is no longer implicit on 3.12, and pipx
# installs CLI tools without hand-rolling a venv for each one.
# pipx defaults to ~/.local/bin, which is not on PATH here, so point it at
# /usr/local/bin instead: "pipx install <tool>" then just works, at build
# time and at run time.
ENV PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin \
    PIPX_MAN_DIR=/usr/local/share/man
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install -y -qq \
    pipx \
    python3-setuptools

# Ansible provisions guest images beyond what cloud-init can express (source
# builds, git checkouts, systemd units).  qemu-tool's --ansible-playbook needs
# both ansible-playbook and ansible-galaxy on PATH; PIPX_BIN_DIR above puts
# them there.  Installed here rather than in ubuntu-qcow2-gen so every guest
# flavour shares one layer.
ARG ANSIBLE_CORE_VERSION=2.21.4
RUN pipx install "ansible-core==${ANSIBLE_CORE_VERSION}" && \
    ansible-playbook --version && \
    ansible-galaxy --version

# The mount point a guest payload is supplied at.  Empty in the image: nothing
# here generates one, and entrypoint.sh errors clearly when nothing is mounted.
RUN mkdir -p /output

# Clone qemu-minimal if repo is provided (separate
# layer so it caches independently of the QEMU build)
WORKDIR /build
RUN set -eux; \
    if [ -z "${QEMU_MINIMAL_REPO}" ]; then \
        echo "QEMU_MINIMAL_REPO not set, skipping"; \
    else \
        git clone "${QEMU_MINIMAL_REPO}" \
            /build/qemu-minimal && \
        cd /build/qemu-minimal && \
        if [ -n "${QEMU_MINIMAL_COMMIT}" ]; then \
            git checkout \
                "${QEMU_MINIMAL_COMMIT}"; \
        fi && \
        git rev-parse HEAD \
            > /build/qemu-minimal-commit.txt; \
    fi

# Install the qemu-tool CLI from the qemu-minimal
# checkout.  Guest builds and boots go through its
# "gen-vm" and "run-vm" subcommands; the standalone
# bash scripts of those names are obsolete and are
# being removed upstream, so nothing may call them.
#
# The checkout is deleted afterwards.  ubuntu-qcow2-gen re-clones it (it needs
# the ansible/ tree, which the wheel does not carry) and `git clone` refuses a
# non-empty target, so leaving it here breaks every guest build.  It also frees
# /build/qemu-minimal/images for the runtime guest mount entrypoint.sh accepts.
RUN set -eux; \
    if [ -d /build/qemu-minimal/qemu ]; then \
        python3 -m venv /opt/qemu-tool; \
        /opt/qemu-tool/bin/pip install --no-cache-dir \
            /build/qemu-minimal/qemu; \
        ln -sf /opt/qemu-tool/bin/qemu-tool \
            /usr/local/bin/qemu-tool; \
        qemu-tool --version; \
    fi; \
    rm -rf /build/qemu-minimal

FROM base AS final

# Copy scripts
COPY ubuntu-qemu-libvfio-user/entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

# Set default environment variables
ENV USERNAME=batesste
ENV QEMU_PATH=/opt/qemu/bin/
ENV PATH=/opt/qemu/bin:${PATH}
ENV SSH_PORT=2222
ENV VCPUS=2
ENV VMEM=4096

# Disable unattended-upgrades to prevent apt lock conflicts.
# Must run after all other apt-get install steps so nothing
# pulls the package back in as a dependency.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get remove -y --purge \
      unattended-upgrades || true && \
    echo 'APT::Periodic::Update-Package-Lists "0";' \
      > /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::Download-Upgradeable-Packages "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::AutocleanInterval "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades && \
    echo 'APT::Periodic::Unattended-Upgrade "0";' \
      >> /etc/apt/apt.conf.d/20auto-upgrades

ENTRYPOINT ["/build/entrypoint.sh"]
