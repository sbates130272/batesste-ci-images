#!/bin/sh
#
# build-vm.sh
#
# Build one guest qcow2 with "qemu-tool gen-vm" and write /output/vm-info.json.
# Run from the Dockerfile; configuration comes from the build ARGs, which reach
# us as environment variables.
#
# Four provisioning layers, matching how the container images work:
#   packages/<VM_PACKAGES>  cloud-init packages, appended to qemu-minimal's
#                           default manifest
#   <VM_PLAYBOOK>           an Ansible playbook from the qemu-minimal checkout,
#                           for anything cloud-init cannot express
#   <KERNEL_REF>            an Ubuntu mainline kernel, installed in a boot of
#                           its own because it is loose .debs in no repository
#   provision/<FLAVOUR>.sh  in-guest steps this repo owns -- a third-party apt
#                           repository, a patched DKMS source, a module built
#                           against the booted kernel -- run in a boot of their
#                           own, after the kernel layer and before the checks,
#                           with assets/<FLAVOUR>/ (when it exists) copied to
#                           /tmp/payload for them to read
#
# KVM is mandatory.  It only works in a RUN --security=insecure step (the
# device node has to be created and opened); anywhere else this script aborts
# rather than fall back to TCG emulation, which is roughly 10x slower.
#

set -eu

QM=/build/qemu-minimal
CTX=/ctx/common

FLAVOUR="${FLAVOUR:-basic}"
FINAL_USERNAME="${USERNAME:-batesste}"
FINAL_VM_NAME="${VM_NAME:-${FINAL_USERNAME}-ci-vm}"
FINAL_PASSWORD="${PASSWORD:-changeme}"
FINAL_RELEASE="${RELEASE:-resolute}"
FINAL_ARCH="${ARCH:-amd64}"
FINAL_VM_SIZE="${VM_SIZE:-512}"
# Build-time only: what gen-vm's provisioning boot and probe-guest's
# verification boot get.  probe-guest reads these out of the environment, so
# both boots are sized the same without threading them through its arguments.
FINAL_VM_VCPUS="${VM_VCPUS:-4}"
FINAL_VM_VMEM="${VM_VMEM:-4096}"
export VM_VCPUS="${FINAL_VM_VCPUS}"
export VM_VMEM="${FINAL_VM_VMEM}"
FINAL_PACKAGES="${VM_PACKAGES:-base.txt}"
FINAL_PLAYBOOK="${VM_PLAYBOOK:-}"
FINAL_KERNEL_REF="${KERNEL_REF:-}"
# Only read by a provision script that installs the AMD kernel driver; inert
# for every other flavour.
FINAL_AMDGPU_DRIVER_VERSION="${AMDGPU_DRIVER_VERSION:-latest}"
# Likewise read only by a provision script that stamps the guest's rdma-core.
FINAL_RDMA_CORE_VERSION="${RDMA_CORE_VERSION:-}"
# Empty means the flavour installs no fio; see the var's note in images.yml.
FINAL_FIO_COMMIT="${FIO_COMMIT:-}"
KERNEL_VERSION=$(uname -r)

echo "=== Guest Image Build Configuration ==="
echo "Cache-bust: ${CACHE_BUST:-none}"
echo "FLAVOUR: ${FLAVOUR}"
echo "QEMU_MINIMAL_REPO: ${QEMU_MINIMAL_REPO:-}"
echo "QEMU_MINIMAL_COMMIT: ${QEMU_MINIMAL_COMMIT:-HEAD}"
echo "VM_NAME: ${FINAL_VM_NAME}"
echo "USERNAME: ${FINAL_USERNAME}"
echo "RELEASE: ${FINAL_RELEASE}"
echo "ARCH: ${FINAL_ARCH}"
echo "VM_SIZE: ${FINAL_VM_SIZE}G (sparse)"
echo "VM_VCPUS: ${FINAL_VM_VCPUS} (build-time boots only)"
echo "VM_VMEM: ${FINAL_VM_VMEM} MiB (build-time boots only)"
echo "VM_PACKAGES: ${FINAL_PACKAGES}"
echo "VM_PLAYBOOK: ${FINAL_PLAYBOOK:-none}"
echo "KERNEL_REF: ${FINAL_KERNEL_REF:-none (release kernel)}"
echo "AMDGPU_DRIVER_VERSION: ${FINAL_AMDGPU_DRIVER_VERSION}"
echo "RDMA_CORE_VERSION: ${FINAL_RDMA_CORE_VERSION:-none}"
echo "FIO_COMMIT: ${FINAL_FIO_COMMIT:-none (no fio in the guest)}"

command -v qemu-tool > /dev/null || {
    echo "Error: qemu-tool not installed!"
    exit 1
}

# /dev/kvm does not exist in the build sandbox, so create it.  Both the mknod
# and the open fail without the insecure entitlement, and that is fatal: there
# is no TCG fallback.
[ -e /dev/kvm ] || mknod /dev/kvm c 10 232 2>/dev/null || true
chmod 666 /dev/kvm 2>/dev/null || true
if ! { [ -c /dev/kvm ] && (exec 3<> /dev/kvm); } 2>/dev/null; then
    echo "Error: /dev/kvm is unusable inside this build step."
    echo "  Build the image with 'docker buildx build --allow" \
         "security.insecure' against a builder created with"
    echo "  --buildkitd-flags '--allow-insecure-entitlement" \
         "security.insecure', on an x86 host with KVM enabled."
    exit 1
fi

mkdir -p "${QM}/images"
cp "${CTX}"/cloud-image-cache/*.img "${QM}/images/" 2>/dev/null || true

# Extra packages are appended to qemu-minimal's default cloud-init manifest,
# one "  - name" entry per line.  ${KERNEL_VERSION} expands to the *host*
# kernel, so a manifest wanting guest-kernel-matched packages should name the
# -generic metapackages instead; the substitution is kept for the few cases
# where host and guest kernels really do have to agree.
PACKAGES_FILE="${QM}/qemu/packages.d/packages-default"
EXTRA="/build/packages/${FINAL_PACKAGES}"
PACKAGES_DIGEST=none
if [ -n "${FINAL_PACKAGES}" ] && [ "${FINAL_PACKAGES}" != "none" ]; then
    [ -f "${EXTRA}" ] || {
        echo "Error: package manifest ${EXTRA} does not exist!"
        ls -la /build/packages/
        exit 1
    }
    PACKAGES_DIGEST=$(sha256sum "${EXTRA}" | cut -d' ' -f1)
    COMBINED=/tmp/packages-combined
    if [ -f "${PACKAGES_FILE}" ]; then
        cat "${PACKAGES_FILE}" > "${COMBINED}"
    else
        echo "# Packages for the ${FLAVOUR} guest" > "${COMBINED}"
    fi
    echo "# Additional packages from ${FINAL_PACKAGES}" >> "${COMBINED}"
    sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" "${EXTRA}" |
        grep -v '^#' | grep -v '^$' |
        sed 's/^/  - /' >> "${COMBINED}"
    PACKAGES_FILE="${COMBINED}"
fi

set -- \
    --vm-name "${FINAL_VM_NAME}" \
    --username "${FINAL_USERNAME}" \
    --password "${FINAL_PASSWORD}" \
    --release "${FINAL_RELEASE}" \
    --arch "${FINAL_ARCH}" \
    --size "${FINAL_VM_SIZE}" \
    --vcpus "${FINAL_VM_VCPUS}" \
    --vmem "${FINAL_VM_VMEM}" \
    --images "${QM}/images" \
    --qemu-path /opt/qemu/bin/ \
    --ssh-key-file /root/.ssh/id_rsa.pub \
    --packages "${PACKAGES_FILE}" \
    --no-backing \
    --kvm

if [ -n "${FINAL_PLAYBOOK}" ]; then
    PLAYBOOK="${QM}/ansible/playbooks/${FINAL_PLAYBOOK}"
    [ -f "${PLAYBOOK}" ] || {
        echo "Error: playbook ${PLAYBOOK} does not exist!"
        ls -la "${QM}/ansible/playbooks/" 2>/dev/null || true
        exit 1
    }
    set -- "$@" --ansible-playbook "${PLAYBOOK}"
fi

# ZScaler on the AMD network re-signs TLS, so the guest needs the corporate
# root CA for in-guest apt and git to work.  Gitignored and absent in CI.
if [ -f "${CTX}/amd-root-ca.crt" ]; then
    echo "Injecting AMD root CA into the guest trust store"
    set -- "$@" --ca-cert "${CTX}/amd-root-ca.crt"
fi

echo "Running qemu-tool gen-vm $*"
qemu-tool gen-vm "$@"

IMAGE="${QM}/images/${FINAL_VM_NAME}.qcow2"
[ -f "${IMAGE}" ] || {
    echo "Error: VM image not created!"
    ls -la "${QM}/images/"
    exit 1
}

cp "${IMAGE}" /output/
cp /root/.ssh/id_rsa /output/id_rsa
cp /root/.ssh/id_rsa.pub /output/id_rsa.pub
chmod 600 /output/id_rsa

# Ubuntu cloud images enable unattended-upgrades, and it costs us twice: its
# timers take the dpkg lock while the layers below are mid-apt, which fails the
# build outright under "set -eu", and in a consumer's long-lived guest it will
# replace the pinned kernel or amdgpu-dkms underneath the patched module the
# image exists to ship.  First of the provisioning boots, so nothing apt-heavy
# runs before it, and unconditional so the basic flavour -- which pins no kernel
# and has no provision script -- is covered too.
HARDEN=/tmp/disable-unattended-upgrades.sh
cat > "${HARDEN}" <<'HARDEN_EOF'
set -eu
# Mask before purging: purging while apt-daily is mid-run blocks on the dpkg
# lock, and dpkg is what the purge needs.
sudo systemctl mask --now apt-daily.timer apt-daily-upgrade.timer
sudo systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
sudo systemctl mask unattended-upgrades.service 2>/dev/null || true

# Masking stops the timers but not a run already in flight, and this is the one
# apt call in the build that can still meet one, so it is the one that waits.
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
    purge -y unattended-upgrades

# Belt and braces: a later apt-get install that pulls the package back in as a
# recommend still finds the periodic knobs zeroed.
sudo tee /etc/apt/apt.conf.d/99-no-unattended-upgrades > /dev/null <<'CONF_EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
CONF_EOF
HARDEN_EOF

echo "Disabling unattended upgrades in the guest"
PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
    "${FINAL_USERNAME}" "${HARDEN}"

# An Ubuntu mainline kernel, when the flavour pins one.  Not expressible as
# cloud-init packages -- these are loose .debs, in no apt repository -- and
# gen-vm's cloud-config has no hook to run a command, so it is a provisioning
# boot of its own: PROBE_PERSIST keeps what it changes, and the verification
# boot that follows sees the guest a consumer will get.
#
# Mainline publishes one build per version rather than one per release, with
# only a handful of base dependencies, so this is independent of RELEASE.  The
# .debs are fetched here rather than in the guest so the proxy and CA setup
# stay on the host side and the exact filenames land in the build log; the
# build stamp is part of them, which is how a "same version" rebuild upstream
# becomes visible instead of silent.
KERNEL_DEBS=none
if [ -n "${FINAL_KERNEL_REF}" ]; then
    MAINLINE="https://kernel.ubuntu.com/mainline/${FINAL_KERNEL_REF}/${FINAL_ARCH}"
    DEBDIR=/tmp/mainline-debs
    rm -rf "${DEBDIR}"
    mkdir -p "${DEBDIR}"

    # -64k is the arm64 page-size variant; taking both would install two
    # kernels and leave grub picking between them.
    NAMES=$(curl -fsSL "${MAINLINE}/" |
        grep -oE 'linux-[a-z-]+-[0-9][^"]*\.deb' |
        grep -v -- '-64k' | sort -u)
    [ -n "${NAMES}" ] || {
        echo "Error: no kernel .debs at ${MAINLINE}/"
        echo "  KERNEL_REF must be a tag published under" \
             "https://kernel.ubuntu.com/mainline/"
        exit 1
    }
    echo "Fetching mainline kernel ${FINAL_KERNEL_REF}:"
    for n in ${NAMES}; do
        echo "  ${n}"
        curl -fsSL -o "${DEBDIR}/${n}" "${MAINLINE}/${n}"
    done
    KERNEL_DEBS=$(echo "${NAMES}" | tr '\n' ' ' | sed 's/ $//')

    KINSTALL=/tmp/install-kernel.sh
    cat > "${KINSTALL}" <<'KERNEL_EOF'
set -eu
# apt rather than dpkg -i so the base dependencies (linux-base, kmod,
# wireless-regdb, an initramfs tool) are resolved from the archive instead of
# leaving dpkg half-configured.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/payload/*.deb
sudo update-grub
rm -rf /tmp/payload
# Nothing here has run on the new kernel yet: grub picks the highest version at
# the next boot, and the verification boot is what confirms it did.
dpkg-query -W -f='${Package}\n' 'linux-image-*' | sed 's/^/installed: /'
KERNEL_EOF

    echo "Installing mainline kernel into the guest"
    PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
        "${FINAL_USERNAME}" "${KINSTALL}" "${DEBDIR}"
    rm -rf "${DEBDIR}"
fi

# Flavour provisioning this repo owns, for steps cloud-init cannot express: a
# third-party apt repository needs a keyring and a sources file, a DKMS module
# has to be patched and then built against the kernel that actually boots.
# Same primitive as the kernel layer above -- PROBE_PERSIST keeps what it
# changes -- and it runs after it, so a module built here is built for the
# pinned kernel and not the one the release shipped.
#
# The script is fed to "bash -s" with no environment of its own, so the few
# build-side values it needs are prepended as assignments rather than threaded
# through probe-guest's arguments. Everything else it decides from the guest.
#
# A flavour whose provisioning needs files in the guest -- patches to apply, a
# generator to run -- puts them in assets/<FLAVOUR>/, and they arrive at
# /tmp/payload.  Same primitive the kernel layer above uses; the script does
# not have to know whether it was given one, only that it is there when its
# flavour ships one.
PROVISION="/build/provision/${FLAVOUR}.sh"
PROVISION_NAME=none
ASSETS_NAME=none
if [ -f "${PROVISION}" ]; then
    PROVISION_NAME="${FLAVOUR}.sh"
    PROV=/tmp/provision.sh
    cat > "${PROV}" <<EOF
set -eu
FLAVOUR='${FLAVOUR}'
RELEASE='${FINAL_RELEASE}'
USERNAME='${FINAL_USERNAME}'
AMDGPU_DRIVER_VERSION='${FINAL_AMDGPU_DRIVER_VERSION}'
RDMA_CORE_VERSION='${FINAL_RDMA_CORE_VERSION}'
FIO_COMMIT='${FINAL_FIO_COMMIT}'
EOF
    cat "${PROVISION}" >> "${PROV}"
    ASSETS="/build/assets/${FLAVOUR}"
    echo "Provisioning the guest with provision/${PROVISION_NAME}"
    if [ -d "${ASSETS}" ]; then
        ASSETS_NAME="${FLAVOUR}"
        echo "  with assets/${FLAVOUR} at /tmp/payload:"
        find "${ASSETS}" -type f | sed "s|^${ASSETS}/|    |"
        PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
            "${FINAL_USERNAME}" "${PROV}" "${ASSETS}"
    else
        PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
            "${FINAL_USERNAME}" "${PROV}"
    fi
fi

# Boot the finished guest once, to read its kernel out of it and to run the
# flavour's checks.  The kernel version is not knowable before the build --
# which is why it is not in the image tag -- and consumers that need a minimum
# (ionic RDMA needs >= 6.18) should not have to boot the image to find out.
# The same boot verifies the guest: one that cannot come up over SSH, or that
# is missing what its flavour promised, fails the build rather than the
# consumer.  Checks live beside the package manifests, so a new flavour is a
# packages file plus a checks file plus an images.yml variant.
PROBE=/tmp/probe.sh
cat > "${PROBE}" <<'PROBE_EOF'
set -eu
printf 'PROBE_KERNEL=%s\n' "$(uname -r)"
# Passwordless sudo and sshd on 22 are the contract for every flavour, so they
# are asserted here rather than repeated in each checks file.  So is the
# absence of unattended upgrades: a later apt step pulling the package back in
# would otherwise be invisible until a consumer's guest upgraded itself.
sudo -n true
test ! -e /usr/bin/unattended-upgrade
test -f /etc/apt/apt.conf.d/99-no-unattended-upgrades
systemctl is-enabled apt-daily.timer 2>/dev/null | grep -qx masked
systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null | grep -qx masked
PROBE_EOF

# A pinned kernel that did not end up being the one that boots is the failure
# this whole layer exists to prevent, and it is invisible from the host: grub
# choosing an older entry, or the .debs installing but the initramfs not being
# rebuilt, both leave a guest that looks fine and is not.
if [ -n "${FINAL_KERNEL_REF}" ]; then
    printf 'case "$(uname -r)" in %s-*) ;; *)\n' \
        "${FINAL_KERNEL_REF#v}" >> "${PROBE}"
    printf '  echo "Error: pinned kernel %s but booted $(uname -r)" >&2\n' \
        "${FINAL_KERNEL_REF}" >> "${PROBE}"
    printf '  exit 1 ;;\nesac\n' >> "${PROBE}"
fi

# Every package the flavour asked for must actually be installed.  cloud-init
# logs an unlocatable package and carries on, so without this a manifest naming
# a package that does not exist in the release ships a guest quietly missing
# what it promised -- which is exactly how linux-modules-extra-generic, absent
# from 26.04 entirely, survived a green build here.
if [ -n "${FINAL_PACKAGES}" ] && [ "${FINAL_PACKAGES}" != "none" ]; then
    REQUESTED=$(sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" "${EXTRA}" |
        grep -v '^#' | grep -v '^$' | tr '\n' ' ')
    printf 'MISSING=""\n' >> "${PROBE}"
    printf 'for p in %s; do\n' "${REQUESTED}" >> "${PROBE}"
    cat >> "${PROBE}" <<'PKG_EOF'
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null |
            grep -q '^install ok installed$'; then
        MISSING="${MISSING} ${p}"
    fi
done
if [ -n "${MISSING}" ]; then
    echo "Error: requested packages missing from guest:${MISSING}" >&2
    exit 1
fi
PKG_EOF
fi

CHECKS="/build/checks/${FLAVOUR}.sh"
if [ -f "${CHECKS}" ]; then
    printf 'echo "Running %s checks" >&2\n' "${FLAVOUR}" >> "${PROBE}"
    # Traced, because an assertion is a bare command under "set -eu": without
    # this a failing check prints nothing at all and the build log says only
    # that the probe exited non-zero.
    printf 'set -x\n' >> "${PROBE}"
    cat "${CHECKS}" >> "${PROBE}"
else
    printf 'echo "No checks file for flavour %s" >&2\n' "${FLAVOUR}" >> "${PROBE}"
fi
echo 'echo PROBE_OK' >> "${PROBE}"

PROBE_OUT=$(probe-guest "/output/${FINAL_VM_NAME}.qcow2" "${FINAL_USERNAME}" \
    "${PROBE}")
printf '%s\n' "${PROBE_OUT}"
echo "${PROBE_OUT}" | grep -qx 'PROBE_OK' || {
    echo "Error: guest checks did not complete"
    exit 1
}
GUEST_KERNEL=$(echo "${PROBE_OUT}" | sed -n 's/^PROBE_KERNEL=//p')
echo "Guest kernel: ${GUEST_KERNEL}"

QEMU_COMMIT_INFO=$(cat /build/qemu-commit.txt 2>/dev/null || echo "unknown")
# Written by the ubuntu-libvfio-user image under /usr/local/share, not
# /build like the two pins above -- reading the wrong path here is why this
# was "unknown" in every vm-info.json before.
LIBVFIO_USER_COMMIT_INFO=$(cat /usr/local/share/libvfio-user-commit.txt \
    2>/dev/null || echo "unknown")
QEMU_MINIMAL_COMMIT_INFO=$(cat /build/qemu-minimal-commit.txt \
    2>/dev/null || echo "unknown")
IMAGE_SIZE=$(stat -c%s "/output/${FINAL_VM_NAME}.qcow2")
IMAGE_INFO=$(/opt/qemu/bin/qemu-img info --output=json \
    "/output/${FINAL_VM_NAME}.qcow2" 2>/dev/null || echo '{}')
IMAGE_FORMAT=$(echo "${IMAGE_INFO}" | jq -r '.format // "qcow2"')
# The sparse ceiling the guest filesystem can grow into, as qemu sees it --
# image_size_bytes is what the payload actually costs to move.
IMAGE_VIRTUAL_SIZE=$(echo "${IMAGE_INFO}" | jq -r '."virtual-size" // 0')
QEMU_VERSION=$(/opt/qemu/bin/qemu-system-x86_64 --version 2>/dev/null |
    head -1 | sed 's/^QEMU emulator version //' || echo "unknown")
# Identifies the key without publishing it, so a consumer can check that the
# keypair in the referrer is the one this disk was built with.
SSH_FINGERPRINT=$(ssh-keygen -lf /output/id_rsa.pub 2>/dev/null |
    awk '{print $2}' || echo "")
CHECKS_NAME=none
if [ -f "${CHECKS}" ]; then
    CHECKS_NAME="${FLAVOUR}.sh"
fi
BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# schema_version 2 added flavour/kernel_release/vm_playbook/packages_digest and
# the kernel pin on top of the v1 keys; 3 adds the virtual size, the qemu
# version, the SSH key fingerprint, the checks script and the build-time boot
# shape; 4 adds the provision script; 5 adds the assets directory that
# provision script was given; 6 adds the unattended-upgrades state.  Every
# earlier key is kept, so a v1 through v5 consumer is unaffected -- read
# schema_version before reaching for anything newer.
#
# What a provision script installed is deliberately not hoisted here: this file
# is flavour-agnostic, and a flavour with its own versions to report writes its
# own record inside the guest (rocjitsu leaves /etc/rocjitsu-guest.json).
#
# kernel_debs carries the resolved filenames, build stamp included, because
# kernel_ref alone does not identify a build.
#
# ci-images-tool.py hoists most of this into the pushed artifact's annotations,
# so "oras manifest fetch" answers the common questions without the referrer.
cat > /output/vm-info.json <<EOF
{
  "schema_version": 6,
  "vm_name": "${FINAL_VM_NAME}",
  "flavour": "${FLAVOUR}",
  "username": "${FINAL_USERNAME}",
  "password": "${FINAL_PASSWORD}",
  "image_path": "/output/${FINAL_VM_NAME}.qcow2",
  "image_format": "${IMAGE_FORMAT}",
  "image_size_bytes": ${IMAGE_SIZE},
  "image_virtual_size_bytes": ${IMAGE_VIRTUAL_SIZE},
  "vm_size_gb": ${FINAL_VM_SIZE},
  "release": "${FINAL_RELEASE}",
  "architecture": "${FINAL_ARCH}",
  "kernel_release": "${GUEST_KERNEL}",
  "qemu_path": "/opt/qemu/bin/",
  "kvm_enabled": true,
  "backing_file": false,
  "ssh_keys": {
    "private_key_path": "/output/id_rsa",
    "public_key_path": "/output/id_rsa.pub",
    "fingerprint": "${SSH_FINGERPRINT}"
  },
  "provisioning": {
    "vm_packages": "${FINAL_PACKAGES}",
    "packages_digest": "${PACKAGES_DIGEST}",
    "vm_playbook": "${FINAL_PLAYBOOK}",
    "kernel_ref": "${FINAL_KERNEL_REF}",
    "kernel_debs": "${KERNEL_DEBS}",
    "provision": "${PROVISION_NAME}",
    "assets": "${ASSETS_NAME}",
    "checks": "${CHECKS_NAME}",
    "unattended_upgrades": "purged"
  },
  "build_info": {
    "qemu_version": "${QEMU_VERSION}",
    "qemu_commit": "${QEMU_COMMIT_INFO}",
    "libvfio_user_commit": "${LIBVFIO_USER_COMMIT_INFO}",
    "qemu_minimal_commit": "${QEMU_MINIMAL_COMMIT_INFO}",
    "build_timestamp": "${BUILD_TIMESTAMP}",
    "build_host_kernel": "${KERNEL_VERSION}",
    "build_vcpus": ${FINAL_VM_VCPUS},
    "build_vmem_mib": ${FINAL_VM_VMEM}
  }
}
EOF

cat /output/vm-info.json
rm -rf "${QM}"
