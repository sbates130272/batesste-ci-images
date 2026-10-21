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
# PROVISION_FLAVOUR overrides which provision script and asset directory that
# layer uses, so a flavour can build on another flavour's recipe rather than
# copy it.  trim/<TRIM>, when set, is a fifth layer after it: a script that
# takes things back *out* of the finished guest, in a boot of its own, before
# the verification boot -- so the checks see what ships.
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
# Whose provision script and assets this flavour uses.  Empty means its own,
# which is every flavour but the slim ones: those are another flavour's guest
# with things removed, and a second copy of a 600-line provision script
# carrying unreviewed kernel patches is the one thing worth avoiding here.
FINAL_PROVISION_FLAVOUR="${PROVISION_FLAVOUR:-${FLAVOUR}}"
# trim/<file>, run after provisioning to take things back out.  Empty for a
# flavour that ships what it provisioned.
FINAL_TRIM="${TRIM:-}"
FINAL_KERNEL_REF="${KERNEL_REF:-}"
# Only read by a provision script that installs the AMD kernel driver; inert
# for every other flavour.
FINAL_AMDGPU_DRIVER_VERSION="${AMDGPU_DRIVER_VERSION:-latest}"
# Where the guest's ROCm userspace lands. Composed in images.yml from
# guest_rocm_version, so a flavour that pins none hands us the bare
# "/opt/rocm/core-"; only a provision script that installs ROCm reads it, and
# that script asserts the directory exists.
FINAL_ROCM_PATH="${ROCM_PATH:-}"
# The same component line, for the therock package names. Empty for a flavour
# that installs no ROCm.
FINAL_ROCM_VERSION="${ROCM_VERSION:-}"
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
echo "PROVISION_FLAVOUR: ${FINAL_PROVISION_FLAVOUR}"
echo "TRIM: ${FINAL_TRIM:-none (ships what it provisioned)}"
echo "KERNEL_REF: ${FINAL_KERNEL_REF:-none (release kernel)}"
echo "AMDGPU_DRIVER_VERSION: ${FINAL_AMDGPU_DRIVER_VERSION}"
echo "ROCM_PATH: ${FINAL_ROCM_PATH:-none (no ROCm in the guest)}"
echo "ROCM_VERSION: ${FINAL_ROCM_VERSION:-none}"
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
# common/cloud-image-cache/ is a *read-only* bind mount of the build context, so
# this seeds gen-vm's image directory but the build can never write back into
# it: an empty cache stays empty until someone drops an .img there by hand, and
# every build then re-downloads ~800 MB with nothing in the log to say so. That
# went unnoticed from 2026-09-02 to 2026-09-25 because the cp discarded both
# stderr and its exit status. Report which way it went instead.
#
# What lands here is not asserted against ${FINAL_RELEASE}/${FINAL_ARCH}: the
# cloud image filenames are gen-vm's convention, upstream in qemu-minimal, and
# duplicating it here is one more thing to drift. A seeded-but-unused cache
# shows up as this line naming the file, followed by gen-vm downloading anyway.
if cp "${CTX}"/cloud-image-cache/*.img "${QM}/images/" 2>/dev/null; then
    echo "Cloud image cache: seeded from common/cloud-image-cache/"
    for img in "${QM}"/images/*.img; do
        echo "  $(basename "${img}") ($(du -h "${img}" | cut -f1))"
    done
else
    echo "Cloud image cache: EMPTY (common/cloud-image-cache/)," \
         "gen-vm will download the ${FINAL_RELEASE} ${FINAL_ARCH} image"
fi

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
        # qemu-minimal's packages-default names linux-generic, which drags in
        # the newest kernel in the archive. On a flavour that pins KERNEL_REF
        # that is a third kernel nothing boots -- the cloud image's, the
        # archive's, and the pinned one -- and dkms autoinstall builds for all
        # three.
        if [ -n "${FINAL_KERNEL_REF}" ]; then
            grep -vE '^[[:space:]]*-[[:space:]]*linux-generic[[:space:]]*$' \
                "${PACKAGES_FILE}" > "${COMBINED}"
        else
            cat "${PACKAGES_FILE}" > "${COMBINED}"
        fi
    else
        echo "# Packages for the ${FLAVOUR} guest" > "${COMBINED}"
    fi
    echo "# Additional packages from ${FINAL_PACKAGES}" >> "${COMBINED}"
    sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" "${EXTRA}" |
        grep -v '^#' | grep -v '^$' |
        sed 's/^/  - /' >> "${COMBINED}"
    PACKAGES_FILE="${COMBINED}"
fi

# One keypair across every flavour and every build, when the build context
# carries one. The Dockerfile generates a throwaway pair per flavour as a
# fallback, which is what made four flavours ship four different keys and a
# rebuild of any one of them ship a fifth -- fine for a disposable guest, but
# it means a consumer cannot hold a known_hosts entry or a key of its own.
#
# Deliberately not in git: this is a private key, the repository is public,
# and a key committed once is published forever. It lives under common/,
# which the build already bind-mounts for the AMD root CA, and which is
# gitignored. A clone without it still builds -- it just gets the old
# per-flavour behaviour, which is why the fallback stays.
if [ -f "${CTX}/ssh/id_rsa" ] && [ -f "${CTX}/ssh/id_rsa.pub" ]; then
    echo "SSH KEY: shared, from common/ssh/"
    install -d -m 700 /root/.ssh
    install -m 600 "${CTX}/ssh/id_rsa" /root/.ssh/id_rsa
    install -m 644 "${CTX}/ssh/id_rsa.pub" /root/.ssh/id_rsa.pub
else
    echo "SSH KEY: per-flavour fallback (no common/ssh/ in the build context)"
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

    # Two observed failure modes against kernel.ubuntu.com, both minutes into a
    # build and neither previously guarded: a .deb transfer died with curl 92
    # (HTTP/2 PROTOCOL_ERROR, stream reset mid-transfer), and the directory
    # listing 503s in bursts that clear within the minute. --http1.1 sidesteps
    # the first by not multiplexing at all -- the reset was not traced to a
    # cause, and nothing here needs HTTP/2, so avoiding it is cheaper than
    # diagnosing it.
    #
    # --retry-all-errors is what makes the retries apply: plain --retry covers
    # timeouts, refused connections and 5xx, and a mid-transfer protocol error
    # is none of those, so without it curl gives up on the first failure. That
    # is why --retry-connrefused, used elsewhere in the repo, would not have
    # caught this.
    CURL_RETRY="--http1.1 --retry 5 --retry-delay 2 --retry-all-errors"

    # -64k is the arm64 page-size variant; taking both would install two
    # kernels and leave grub picking between them.
    # shellcheck disable=SC2086
    NAMES=$(curl -fsSL ${CURL_RETRY} --max-time 120 "${MAINLINE}/" |
        grep -oE 'linux-[a-z-]+-[0-9][^"]*\.deb' |
        grep -v -- '-64k' | sort -u)
    [ -n "${NAMES}" ] || {
        echo "Error: no kernel .debs at ${MAINLINE}/"
        echo "  KERNEL_REF must be a tag published under" \
             "https://kernel.ubuntu.com/mainline/"
        exit 1
    }
    echo "Fetching mainline kernel ${FINAL_KERNEL_REF}:"
    # No --max-time: linux-modules is ~100 MB and this runs on links where the
    # 120s the listing gets is not enough for it. The retry budget above is the
    # guard against a hung transfer, not a deadline.
    for n in ${NAMES}; do
        echo "  ${n}"
        # shellcheck disable=SC2086
        curl -fsSL ${CURL_RETRY} -o "${DEBDIR}/${n}" "${MAINLINE}/${n}"
    done
    KERNEL_DEBS=$(echo "${NAMES}" | tr '\n' ' ' | sed 's/ $//')

    KINSTALL=/tmp/install-kernel.sh
    printf 'KPIN=%s\n' "${FINAL_KERNEL_REF#v}" > "${KINSTALL}"
    cat >> "${KINSTALL}" <<'KERNEL_EOF'
set -eu
# apt rather than dpkg -i so the base dependencies (linux-base, kmod,
# wireless-regdb, an initramfs tool) are resolved from the archive instead of
# leaving dpkg half-configured.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/payload/*.deb
sudo update-grub
rm -rf /tmp/payload

# Which kernel the pin actually resolved to.  The .deb names carry the ABI
# (7.2.4-070204-generic) and the pin does not, so this is read back rather
# than reconstructed.
KREL=$(ls -1 /boot/vmlinuz-"${KPIN}"-* 2>/dev/null | sed 's|.*/vmlinuz-||' |
    sort -V | tail -1)
[ -n "${KREL}" ] || {
    echo "Error: no /boot/vmlinuz-${KPIN}-* after installing the .debs" >&2
    exit 1
}

# Pin grub's default to that kernel by menuentry id.
#
# Not left to "grub picks the highest version", which is what this used to
# rely on: GRUB_DEFAULT=0 selects whatever 10_linux emitted first, and the
# release's own HWE kernel keeps being installed alongside this one.  A guest
# that silently boots 7.0.x instead of the pinned mainline is the failure the
# whole kernel layer exists to prevent, and it is invisible from the host.
#
# By id rather than by menuentry title: the title is generated text that
# changes with the kernel version and with Ubuntu's grub templates, so a
# hardcoded title is a string that rots.  The ids are read out of the grub.cfg
# that update-grub just produced, and the submenu>entry form is what grub wants
# for an entry nested under "Advanced options".
#
# A grub.d snippet rather than an edit to /etc/default/grub, for the reason
# the amdgpu blacklist uses one: 50-cloudimg-settings.cfg is sourced after the
# main file and would overwrite it.  99- sorts last.
# sudo throughout: grub.cfg is mode 600 and these run as the guest user, so
# an unprivileged read returns nothing and the ids come back empty -- which
# looks exactly like "no such entry" and is not.
SUBMENU_ID=$(sudo sed -n "s/^submenu .*\$menuentry_id_option '\([^']*\)'.*/\1/p" \
    /boot/grub/grub.cfg | head -1)
ENTRY_ID=$(sudo sed -n "s/^[[:space:]]*menuentry .*\$menuentry_id_option '\([^']*\)'.*/\1/p" \
    /boot/grub/grub.cfg | grep -- "-${KREL}-advanced-" | head -1)
if [ -z "${SUBMENU_ID}" ] || [ -z "${ENTRY_ID}" ]; then
    echo "Error: no grub menuentry id for ${KREL}" >&2
    sudo grep -nE '^(submenu|[[:space:]]*menuentry)' /boot/grub/grub.cfg >&2
    exit 1
fi
sudo install -d -m 0755 /etc/default/grub.d
printf 'GRUB_DEFAULT="%s>%s"\n' "${SUBMENU_ID}" "${ENTRY_ID}" |
    sudo tee /etc/default/grub.d/99-pinned-kernel.cfg > /dev/null
sudo update-grub

# Asserted here as well as in the verification boot: this is where the cause
# is still on screen if the id did not survive into the generated config.
#
# Parsed rather than grepped for a literal, because 00_header does not write
# the line the obvious way. It emits
#
#   if [ "${next_entry}" ] ; then
#      set default="${next_entry}"
#   else
#      set default="<GRUB_DEFAULT>"
#   fi
#
# so the line is indented inside an if/else -- an anchored "^set default"
# never matches it -- and the *first* occurrence is grub's own next_entry
# variable rather than our value. Take the first one that is not a ${...}
# reference.
GRUB_SET=$(sudo sed -n 's/^[[:space:]]*set default="\(.*\)"$/\1/p' \
    /boot/grub/grub.cfg | grep -v '\${' | head -1)
if [ "${GRUB_SET}" != "${SUBMENU_ID}>${ENTRY_ID}" ]; then
    echo "Error: grub default is '${GRUB_SET}', not the pinned ${KREL}" >&2
    sudo grep -n 'set default=' /boot/grub/grub.cfg >&2
    exit 1
fi
echo "grub default pinned to ${KREL}"
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
#
# PROVISION_FLAVOUR names whose script and assets to use, defaulting to this
# flavour's own.  A flavour that points at another one gets that recipe
# verbatim -- which is the point: the patches and the DKMS handling exist once.
PROVISION="/build/provision/${FINAL_PROVISION_FLAVOUR}.sh"
PROVISION_NAME=none
ASSETS_NAME=none
if [ -f "${PROVISION}" ]; then
    PROVISION_NAME="${FINAL_PROVISION_FLAVOUR}.sh"
    PROV=/tmp/provision.sh
    cat > "${PROV}" <<EOF
set -eu
FLAVOUR='${FLAVOUR}'
RELEASE='${FINAL_RELEASE}'
USERNAME='${FINAL_USERNAME}'
AMDGPU_DRIVER_VERSION='${FINAL_AMDGPU_DRIVER_VERSION}'
ROCM_PATH='${FINAL_ROCM_PATH}'
ROCM_VERSION='${FINAL_ROCM_VERSION}'
RDMA_CORE_VERSION='${FINAL_RDMA_CORE_VERSION}'
FIO_COMMIT='${FINAL_FIO_COMMIT}'
EOF
    cat "${PROVISION}" >> "${PROV}"
    ASSETS="/build/assets/${FINAL_PROVISION_FLAVOUR}"
    echo "Provisioning the guest with provision/${PROVISION_NAME}"
    if [ -d "${ASSETS}" ]; then
        ASSETS_NAME="${FINAL_PROVISION_FLAVOUR}"
        echo "  with assets/${ASSETS_NAME} at /tmp/payload:"
        find "${ASSETS}" -type f | sed "s|^${ASSETS}/|    |"
        PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
            "${FINAL_USERNAME}" "${PROV}" "${ASSETS}"
    else
        PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
            "${FINAL_USERNAME}" "${PROV}"
    fi
fi

# The trim layer: a script that takes things back out of the finished guest.
#
# A boot of its own, after provisioning and before the verification boot, so
# the checks run against what actually ships -- a trim that breaks the guest
# has to fail this build and not a consumer's job.  Same preamble as the
# provision layer, because a trim script needs the same few build-side values
# (ROCM_PATH to know what to delete under, USERNAME to write the guest's own
# notes as the login user).
#
# It is flavour-agnostic machinery: trim/<file> is named by the flavour, so a
# future flavour wanting a different subtraction adds a file rather than a
# branch here.
TRIM_NAME=none
if [ -n "${FINAL_TRIM}" ]; then
    TRIM_SCRIPT="/build/trim/${FINAL_TRIM}"
    [ -f "${TRIM_SCRIPT}" ] || {
        echo "Error: trim script ${TRIM_SCRIPT} does not exist!"
        ls -la /build/trim/ 2>/dev/null || true
        exit 1
    }
    TRIM_NAME="${FINAL_TRIM}"
    TRIMSH=/tmp/trim.sh
    cat > "${TRIMSH}" <<EOF
set -eu
FLAVOUR='${FLAVOUR}'
RELEASE='${FINAL_RELEASE}'
USERNAME='${FINAL_USERNAME}'
ROCM_PATH='${FINAL_ROCM_PATH}'
ROCM_VERSION='${FINAL_ROCM_VERSION}'
KERNEL_REF='${FINAL_KERNEL_REF}'
EOF
    cat "${TRIM_SCRIPT}" >> "${TRIMSH}"
    echo "Trimming the guest with trim/${TRIM_NAME}"
    PROBE_PERSIST=1 probe-guest "/output/${FINAL_VM_NAME}.qcow2" \
        "${FINAL_USERNAME}" "${TRIMSH}"

    # The trim's fstrim punched holes in the qcow2 -- probe-guest attaches the
    # disk with discard=unmap so it reaches the image rather than stopping at
    # the guest filesystem -- but the file still carries the L2 slack and the
    # cluster order of everything that has been written and deleted since the
    # cloud image was copied.  A convert rewrites it compactly.
    #
    # Uncompressed on purpose: -c would make the payload smaller again and pay
    # for it on every guest read, which is the opposite of what a slim flavour
    # is for.
    BEFORE=$(stat -c%s "/output/${FINAL_VM_NAME}.qcow2")
    echo "Compacting the guest image (${BEFORE} bytes before)"
    /opt/qemu/bin/qemu-img convert -O qcow2 \
        "/output/${FINAL_VM_NAME}.qcow2" "/tmp/${FINAL_VM_NAME}.compact.qcow2"
    mv "/tmp/${FINAL_VM_NAME}.compact.qcow2" \
        "/output/${FINAL_VM_NAME}.qcow2"
    AFTER=$(stat -c%s "/output/${FINAL_VM_NAME}.qcow2")
    echo "Compacted: ${BEFORE} -> ${AFTER} bytes"
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

# Everything below is read out of the guest and ends up in vm-info.json, so a
# consumer can ask the manifest instead of booting the image to find out.
#
# The running kernel above is not the whole story: the release keeps its own
# HWE kernel installed alongside a pinned mainline one, so "which kernels are
# here" and "which one boots next" are separate questions and both belong in
# the manifest.
printf 'PROBE_KERNELS=%s\n' \
    "$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' |
        sort -V | tr '\n' ',' | sed 's/,$//')"
# sudo: grub.cfg is mode 600. Without it this reads nothing and the manifest
# records a default nobody checked.
# Named for the key it is emitted as, because the pinned-kernel assertion
# appended to this script later reads the variable by that name -- under
# `set -u` a second spelling is not a typo that lingers, it is an unbound
# variable that fails the probe.
PROBE_GRUB_DEFAULT_ID=$(sudo sed -n 's/^[[:space:]]*set default="\(.*\)"$/\1/p' \
    /boot/grub/grub.cfg | grep -v '\${' | head -1)
printf 'PROBE_GRUB_DEFAULT_ID=%s\n' "${PROBE_GRUB_DEFAULT_ID}"
# Which kernel that selects, which is the question a consumer actually has.
#
# Two shapes.  A flavour that pins a kernel gets an explicit id from the
# kernel layer, and Ubuntu's generated ids carry the release
# (gnulinux-<rel>-advanced-<uuid>), so it resolves by inspection.  A flavour
# that pins none leaves GRUB_DEFAULT at 0, so the index is resolved by
# reading the first menuentry's linux line -- leaving this empty would mean
# the manifest cannot answer the one question it exists to answer.
PROBE_GRUB_DEFAULT_KERNEL=$(printf '%s' "${PROBE_GRUB_DEFAULT_ID##*>}" |
    sed -n 's/^gnulinux-\(.*\)-advanced-.*/\1/p')
if [ -z "${PROBE_GRUB_DEFAULT_KERNEL}" ]; then
    PROBE_GRUB_DEFAULT_KERNEL=$(sudo awk '
        /^menuentry/ { n++ }
        n == 1 && $1 == "linux" {
            sub(/.*vmlinuz-/, "", $2); print $2; exit
        }' /boot/grub/grub.cfg)
fi
printf 'PROBE_GRUB_DEFAULT_KERNEL=%s\n' "${PROBE_GRUB_DEFAULT_KERNEL}"

. /etc/os-release
printf 'PROBE_UBUNTU_VERSION=%s\n' "${VERSION_ID:-unknown}"
printf 'PROBE_UBUNTU_CODENAME=%s\n' "${VERSION_CODENAME:-unknown}"

# DKMS state, not just the source tree: a module built for a kernel that is
# not the one booting is exactly the skew this manifest should expose.
if command -v dkms > /dev/null; then
    printf 'PROBE_DKMS=%s\n' \
        "$(dkms status 2>/dev/null | tr '\n' ';' | sed 's/;$//')"
else
    printf 'PROBE_DKMS=\n'
fi

# ROCm, when the flavour installed any.  The therock packages live under a
# versioned component directory, so the path is as much a fact as the version.
if [ -e /etc/profile.d/rocm.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/rocm.sh
    printf 'PROBE_ROCM_PATH=%s\n' "${ROCM_PATH:-}"
    printf 'PROBE_ROCM_VERSION=%s\n' \
        "$(dpkg-query -W -f='${Version}' 'amdrocm-runtime-dev*' 2>/dev/null |
            head -1)"
else
    printf 'PROBE_ROCM_PATH=\n'
    printf 'PROBE_ROCM_VERSION=\n'
fi

# The host keys the guest will present, so a consumer can pin them instead of
# meeting a new fingerprint on first contact.  The keypair in /output is the
# login key and is recorded separately by the host side.
printf 'PROBE_SSH_HOST_KEYS=%s\n' \
    "$(for f in /etc/ssh/ssh_host_*_key.pub; do
        [ -e "${f}" ] || continue
        ssh-keygen -l -f "${f}" 2>/dev/null | awk '{print $4" "$2}'
    done | tr '\n' ';' | sed 's/;$//')"

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
    # And what the *next* boot will take, which is a different question. This
    # boot inherits whatever grub chose when the kernel layer ran; a consumer
    # launching the published image gets whatever the default entry says now.
    # A guest reported against 20261007.g677e113 booted the release's HWE
    # kernel rather than the pinned mainline, which is the shape of failure
    # this closes -- the running kernel was right and the default entry was
    # not, so nothing in the build noticed.
    printf 'case "${PROBE_GRUB_DEFAULT_KERNEL}" in %s-*) ;; *)\n' \
        "${FINAL_KERNEL_REF#v}" >> "${PROBE}"
    printf '  echo "Error: grub default resolves to' \
        >> "${PROBE}"
    printf ' ${PROBE_GRUB_DEFAULT_KERNEL:-<unset>} (id' >> "${PROBE}"
    printf ' ${PROBE_GRUB_DEFAULT_ID}), not the pinned %s" >&2\n' \
        "${FINAL_KERNEL_REF}" >> "${PROBE}"
    printf '  exit 1 ;;\nesac\n' >> "${PROBE}"
fi

# Every package the flavour asked for must actually be installed.  cloud-init
# logs an unlocatable package and carries on, so without this a manifest naming
# a package that does not exist in the release ships a guest quietly missing
# what it promised -- which is exactly how linux-modules-extra-generic, absent
# from 26.04 entirely, survived a green build here.
#
# Not for a trimmed flavour.  One of those installs a manifest in order to
# build with it and then purges most of it, so this assertion is guaranteed
# false there and the guest is not missing anything it promised.  Said out
# loud rather than quietly arranged: what the trimmed guest does carry is
# asserted by its own checks file, including the negatives.
if [ -n "${FINAL_TRIM}" ]; then
    echo "Skipping the package-presence assertion: trim/${TRIM_NAME} removes" \
         "packages ${FINAL_PACKAGES} asked for; checks/${FLAVOUR}.sh is what" \
         "asserts this guest's contents"
elif [ -n "${FINAL_PACKAGES}" ] && [ "${FINAL_PACKAGES}" != "none" ]; then
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

# The rest of what the guest said about itself, for the manifest.  Read with
# the same sed as above rather than eval'd: these are values from inside the
# guest and they land in JSON, so they are data here and nothing else.
probe_val() { echo "${PROBE_OUT}" | sed -n "s/^$1=//p" | head -1; }
GUEST_KERNELS=$(probe_val PROBE_KERNELS)
GUEST_GRUB_DEFAULT_ID=$(probe_val PROBE_GRUB_DEFAULT_ID)
GUEST_GRUB_DEFAULT_KERNEL=$(probe_val PROBE_GRUB_DEFAULT_KERNEL)
GUEST_UBUNTU_VERSION=$(probe_val PROBE_UBUNTU_VERSION)
GUEST_UBUNTU_CODENAME=$(probe_val PROBE_UBUNTU_CODENAME)
GUEST_DKMS=$(probe_val PROBE_DKMS)
GUEST_ROCM_PATH=$(probe_val PROBE_ROCM_PATH)
GUEST_ROCM_VERSION=$(probe_val PROBE_ROCM_VERSION)
GUEST_SSH_HOST_KEYS=$(probe_val PROBE_SSH_HOST_KEYS)
echo "Guest kernels: ${GUEST_KERNELS}"
echo "Grub default: ${GUEST_GRUB_DEFAULT_KERNEL:-<index>} (${GUEST_GRUB_DEFAULT_ID})"

# ";"-and-","-separated on the wire because the probe emits one line per fact;
# split back into JSON arrays so consumers do not have to know that.
json_array() {
    printf '%s' "$1" | tr "$2" '\n' | jq -R . | jq -s -c .
}
JSON_KERNELS=$(json_array "${GUEST_KERNELS}" ',')
JSON_DKMS=$(json_array "${GUEST_DKMS}" ';')
JSON_SSH_HOST_KEYS=$(json_array "${GUEST_SSH_HOST_KEYS}" ';')

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
# provision script was given; 6 adds the unattended-upgrades state; 7 adds the
# kernels block, dkms, rocm, os and the guest's SSH host keys; 8 adds the
# provision flavour and the trim script.  Every earlier key is kept, so a v1
# through v7 consumer is unaffected -- read schema_version before reaching for
# anything newer.
#
# v8's two keys answer "is this the guest it looks like": provision_flavour
# names whose recipe built it, which is not the flavour for a slim variant,
# and trim names what was taken back out afterwards.  A consumer that needs a
# toolchain in the guest should branch on trim being empty rather than on the
# flavour name.
#
# v7 exists because kernel_release alone was not enough to describe a guest.
# It is the kernel the verification boot happened to be running, and a release
# keeps its own HWE kernel installed beside a pinned mainline one, so it said
# nothing about which kernel a consumer's launch would take.  kernels.default
# is that answer, read from the grub config rather than from uname.
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
  "schema_version": 8,
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
  "kernels": {
    "booted": "${GUEST_KERNEL}",
    "default": "${GUEST_GRUB_DEFAULT_KERNEL}",
    "default_grub_id": "${GUEST_GRUB_DEFAULT_ID}",
    "installed": ${JSON_KERNELS}
  },
  "os": {
    "distribution": "ubuntu",
    "version": "${GUEST_UBUNTU_VERSION}",
    "codename": "${GUEST_UBUNTU_CODENAME}"
  },
  "dkms": ${JSON_DKMS},
  "rocm": {
    "path": "${GUEST_ROCM_PATH}",
    "version": "${GUEST_ROCM_VERSION}"
  },
  "qemu_path": "/opt/qemu/bin/",
  "kvm_enabled": true,
  "backing_file": false,
  "ssh_keys": {
    "private_key_path": "/output/id_rsa",
    "public_key_path": "/output/id_rsa.pub",
    "fingerprint": "${SSH_FINGERPRINT}",
    "host_key_fingerprints": ${JSON_SSH_HOST_KEYS}
  },
  "provisioning": {
    "vm_packages": "${FINAL_PACKAGES}",
    "packages_digest": "${PACKAGES_DIGEST}",
    "vm_playbook": "${FINAL_PLAYBOOK}",
    "kernel_ref": "${FINAL_KERNEL_REF}",
    "kernel_debs": "${KERNEL_DEBS}",
    "provision": "${PROVISION_NAME}",
    "provision_flavour": "${FINAL_PROVISION_FLAVOUR}",
    "assets": "${ASSETS_NAME}",
    "trim": "${TRIM_NAME}",
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
