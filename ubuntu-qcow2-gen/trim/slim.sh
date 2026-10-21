# shellcheck shell=bash
#
# The "slim" trim, run by build-vm.sh in a PROBE_PERSIST boot after the
# flavour's provision script and before the verification boot.  It takes things
# back *out* of a finished guest: this is the same image the fat flavour
# produces -- same kernel, same patched amdgpu, same ionic half, same firmware
# -- with everything a runtime consumer cannot use removed.
#
# "Runtime consumer" is the contract, and it is a real loss: the guest that
# comes out of this cannot compile anything.  No gcc, no headers, no DKMS
# source.  A lane that builds ionic-ernic or hipObject inside the guest wants
# the fat flavour; this one is for booting a prebuilt binary against the two
# emulated devices, fast.
#
# Appended to a preamble that sets "set -eu" plus FLAVOUR, RELEASE, USERNAME,
# ROCM_PATH, ROCM_VERSION and KERNEL_REF, so any failing command fails the
# image build.  Runs as the guest user; root comes from sudo.
#
# Order matters.  Each section assumes the ones above it have run -- above all,
# the amdgpu module has to be rescued before anything purges the package that
# owns it.

echo "=== slim trim ==="
KVER=$(uname -r)
echo "kernel: ${KVER}  rocm: ${ROCM_PATH}"
USED_BEFORE=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
echo "root filesystem used before: ${USED_BEFORE} MiB"

export DEBIAN_FRONTEND=noninteractive
APT="sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120"

# Purge the names in "$@" that are actually installed, and say nothing about
# the ones that are not.
#
# apt-get purge fails the whole transaction on a name it has never heard of,
# and these lists necessarily name packages that may or may not be here -- a
# metapackage the release renamed, a daemon the cloud image dropped.  The
# obvious fix is "|| true", and it is the wrong one: it also swallows a purge
# that failed for a real reason, in a script whose entire job is removing
# things.  Filtering first means every purge that runs is one that must work.
purge_installed() {
    _p=""
    for _name in "$@"; do
        if dpkg-query -W -f='${Status}' "${_name}" 2>/dev/null |
                grep -q '^install ok installed$'; then
            _p="${_p} ${_name}"
        fi
    done
    if [ -n "${_p}" ]; then
        echo "purging:${_p}"
        # shellcheck disable=SC2086
        ${APT} purge -y ${_p}
    fi
}

# --- 1. amdgpu: keep the module, drop the source -------------------------
#
# /usr/src/amdgpu-* is ~2 GB and exists so a later "dkms autoinstall" can
# rebuild the patched driver for a new kernel.  This guest installs no kernels,
# so it buys nothing here -- but removing it means removing amdgpu-dkms, and
# that package's postrm runs "dkms remove", which deletes the module the fat
# build spent twenty minutes producing.
#
# So the module is saved first and reinstated afterwards, rather than hoping
# the postrm leaves it alone.  Everything below asserts itself: this is the one
# irreversible step in the trim, and a guest that comes out of it without a
# loadable patched amdgpu is worth no bytes at all.
AMDGPU_KO=$(modinfo -n amdgpu)
case "${AMDGPU_KO}" in
    */updates/dkms/*) ;;
    *)
        echo "Error: modprobe resolves amdgpu to ${AMDGPU_KO}, not the DKMS" \
             "module; the fat build should have failed before this ran" >&2
        exit 1
        ;;
esac
# Recorded before the purge so the restored module can be checked against it.
AMDGPU_FW_NAMES=$(modinfo -F firmware "${AMDGPU_KO}" | sort | tr '\n' ' ')
AMDGPU_MODVER=$(modinfo -F version "${AMDGPU_KO}")
AMDGPU_BASENAME=$(basename "${AMDGPU_KO}")
sudo install -d -m 0755 /var/tmp/slim-save
sudo cp -a "${AMDGPU_KO}" "/var/tmp/slim-save/${AMDGPU_BASENAME}"
echo "saved ${AMDGPU_KO} (version ${AMDGPU_MODVER})"

# amdgpu-dkms-firmware is a dependency of amdgpu-dkms, so purging the latter
# makes it an autoremove candidate -- and it is the package carrying every real
# gc_12_1_0 blob the emulated device needs.  Marked manual so autoremove below
# cannot take it.
sudo apt-mark manual amdgpu-dkms-firmware
AMDGPU_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms)
FW_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms-firmware)
${APT} purge -y amdgpu-dkms
sudo rm -rf /usr/src/amdgpu-* /var/lib/dkms

# Back where modprobe looks.  depmod rather than trusting the postrm to have
# left modules.dep alone: it did run "dkms remove", and that rewrites it.
sudo install -d -m 0755 "/lib/modules/${KVER}/updates/dkms"
sudo cp -a "/var/tmp/slim-save/${AMDGPU_BASENAME}" \
    "/lib/modules/${KVER}/updates/dkms/${AMDGPU_BASENAME}"
sudo rm -rf /var/tmp/slim-save
sudo depmod -a "${KVER}"

# The assertion the whole section turns on.
RESTORED=$(modinfo -n amdgpu)
case "${RESTORED}" in
    */updates/dkms/*) ;;
    *)
        echo "Error: after the trim, modprobe resolves amdgpu to" \
             "${RESTORED:-<nothing>} rather than the restored DKMS module" >&2
        exit 1
        ;;
esac
test "$(modinfo -F version "${RESTORED}")" = "${AMDGPU_MODVER}"
test "$(modinfo -F firmware "${RESTORED}" | sort | tr '\n' ' ')" \
    = "${AMDGPU_FW_NAMES}"
modinfo -F parm "${RESTORED}" | grep -q '^emu_mode:'
echo "amdgpu.ko: ${RESTORED} (version ${AMDGPU_MODVER}, source tree removed)"

# --- 2. kernels and firmware ---------------------------------------------
#
# The release keeps its own kernel installed beside the mainline pin, and this
# guest boots exactly one of them.  The other is a kernel, its modules, its
# headers and an initramfs nobody will ever select -- and it is also the thing
# grub could fall back to, which is the failure the fat flavour's pinned-kernel
# assertions exist to catch.  Removing it makes that unrepresentable.
#
# Matched on the version in the package name rather than on a list: the
# mainline .debs and the archive's are named differently and both shapes carry
# the version, so this keeps whatever "uname -r" says and purges the rest.
STALE=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-modules-*' \
    2>/dev/null | grep -v -- "${KVER}" || true)
if [ -n "${STALE}" ]; then
    echo "purging kernels that are not ${KVER}:"
    echo "${STALE}" | sed 's/^/  /'
    # shellcheck disable=SC2086
    ${APT} purge -y ${STALE}
fi

# Headers go wholesale: nothing builds a module in this guest any more, and
# section 1 already removed the only DKMS package that would have been
# triggered by their removal.
HEADERS=$(dpkg-query -W -f='${Package}\n' 'linux-headers-*' 2>/dev/null || true)
if [ -n "${HEADERS}" ]; then
    # shellcheck disable=SC2086
    ${APT} purge -y ${HEADERS}
fi
sudo rm -rf /usr/src/linux-headers-*

# linux-firmware is ~1.5 GB of microcode for hardware that cannot exist here:
# the guest sees virtio devices and two emulated functions, and the blobs those
# need come from amdgpu-dkms-firmware, which is a different package and stays.
purge_installed linux-firmware

${APT} autoremove --purge -y

# One kernel, and it is the one running.
KERNELS=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)
test "${KERNELS}" -eq 1
test -e "/boot/vmlinuz-${KVER}"

# --- 3. the toolchain ----------------------------------------------------
#
# Everything in packages/ernic-rocjitsu.txt that exists to *build* something.
# The manifest still asks for all of it, because the fat provision script this
# flavour reuses needs it to build amdgpu; build-vm.sh skips its
# package-presence assertion for a trimmed flavour for exactly this reason.
#
# dkms is in this list and not in section 1, and the order is not a style
# choice: amdgpu-dkms's postrm invokes the dkms binary, so purging dkms first
# leaves that package half-removed and the build dead at a dpkg error.
#
# Kept, deliberately: rdma-core, ibverbs-utils and perftest (the ionic half is
# the point of the flavour, and ib_send_bw and friends are runtime tools),
# pciutils, nvme-cli, kmod, initramfs-tools, curl, ca-certificates and the base
# python3 -- megabytes, all of them, and each one is something a consumer would
# otherwise have to install over SSH in a guest with no compiler.
purge_installed \
    build-essential g++ gcc cpp make cmake ninja-build pkg-config dkms git \
    python3-dev python3-docutils libstdc++-14-dev \
    libdrm-dev libssl-dev libcli11-dev libnl-3-dev libnl-route-3-dev \
    libudev-dev libsystemd-dev libibverbs-dev \
    pipx python3-venv rsync

# The compiler packages above are metapackages and versioned names both; take
# whatever is left of either, plus the ROCm headers-only package, which is
# useless without a compiler to point at them.
#
# gcc-<n>-base is excluded: it is not a compiler, it is what libstdc++6 and
# libgcc-s1 depend on, and purging it takes the C++ runtime -- and therefore
# the HIP runtime this flavour exists to ship -- with it.
LEFTOVER=$(dpkg-query -W -f='${Package} ${Status}\n' 'gcc-*' 'g++-*' 'cpp-*' \
    'libgcc-*-dev' 'linux-libc-dev' 'amdrocm-blas-dev*' 2>/dev/null |
    grep ' install ok installed$' | cut -d' ' -f1 | grep -v -- '-base$' || true)
if [ -n "${LEFTOVER}" ]; then
    echo "purging:" "${LEFTOVER}"
    # shellcheck disable=SC2086
    ${APT} purge -y ${LEFTOVER}
fi
${APT} autoremove --purge -y

# --- 4. ROCm, runtime only -----------------------------------------------
#
# amdrocm-runtime-dev stays installed -- it is what provides libamdhip64 and
# libhsa-runtime64, which is the whole ROCm half of this guest -- but most of
# what it unpacks is for building: LLVM and clang are the single largest
# directory in the image, and headers and CMake config files are no use in a
# guest with no compiler.
#
# These are dpkg-owned paths, so dpkg -V will report them missing.  That is a
# deliberate, recorded property of a slim guest rather than damage: see
# /etc/slim-trim.json below, and note that the checks assert the surviving
# libraries through ldconfig rather than through package state.
#
# amdgcn/ is kept: it is the device bitcode the runtime loads, not a build
# artifact, and a guest without it fails at dispatch rather than at link.
test -n "${ROCM_PATH}"
test -d "${ROCM_PATH}"
ROCM_DELETED=""
for d in lib/llvm include lib/cmake share/doc share/man lib/rocmcc; do
    if [ -e "${ROCM_PATH}/${d}" ]; then
        sudo rm -rf "${ROCM_PATH:?}/${d}"
        ROCM_DELETED="${ROCM_DELETED}${ROCM_DELETED:+,}\"${d}\""
    fi
done
sudo find "${ROCM_PATH}" -name '*.a' -delete
sudo ldconfig
ldconfig -p | grep -q libamdhip64
ldconfig -p | grep -q libhsa-runtime64

# --- 5. boot speed -------------------------------------------------------
#
# cloud-init is disabled rather than purged.  Its job here is done -- the user,
# the key and /etc/netplan/50-cloud-init.yaml were all written during the fat
# build and are plain files on disk -- but its purge hooks reach into
# /etc/cloud and /var/lib/cloud, and the netplan file is what gives this guest
# an address.  Masking costs a few MB and cannot take the network with it.
#
# The consequence for a consumer is real and is documented: no seed ISO, no
# NoCloud userdata, no injecting an SSH key at launch.  The baked-in login and
# the keypair published beside the image are how you get in.
sudo touch /etc/cloud/cloud-init.disabled
sudo systemctl mask cloud-init.service cloud-init-local.service \
    cloud-config.service cloud-final.service 2>/dev/null || true

purge_installed snapd modemmanager packagekit apport whoopsie \
    multipath-tools lxd-installer
sudo rm -rf /var/lib/snapd /snap /var/cache/snapd

# systemd-networkd-wait-online is the classic silent stall: it blocks boot for
# up to two minutes waiting on an interface that is already configured.
for unit in systemd-networkd-wait-online.service \
            NetworkManager-wait-online.service \
            e2scrub_all.timer e2scrub_reap.service man-db.timer \
            motd-news.timer apt-daily.timer apt-daily-upgrade.timer; do
    sudo systemctl mask "${unit}" 2>/dev/null || true
done

# A file of its own rather than an edit to /etc/default/grub, for the reason
# every other grub change in this repo uses one: 50-cloudimg-settings.cfg is
# sourced afterwards and would overwrite it.  Separate from
# 99-pinned-kernel.cfg, which owns GRUB_DEFAULT -- different variables, both
# sourced, neither clobbering the other.
#
# GRUB_RECORDFAIL_TIMEOUT matters as much as GRUB_TIMEOUT: without it an
# unclean shutdown -- which is how a CI guest usually ends -- makes the *next*
# boot sit at the menu for 30 seconds.
sudo install -d -m 0755 /etc/default/grub.d
sudo tee /etc/default/grub.d/99-slim-fastboot.cfg > /dev/null <<'EOF'
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
EOF

# A dep-only initramfs carries the handful of modules this machine actually
# needs instead of every storage and network driver in the tree.  The
# amdgpu-exclude hook from provisioning still runs, and the "no amdgpu.ko in
# any initrd" assertion in the checks still has to pass afterwards -- which is
# the point of rebuilding here rather than leaving the fat initramfs in place.
sudo tee /etc/initramfs-tools/conf.d/slim.conf > /dev/null <<'EOF'
MODULES=dep
COMPRESS=zstd
EOF
sudo update-initramfs -u -k all
sudo update-grub
# The pinned-kernel default and the amdgpu blacklist both have to survive a
# regenerated grub.cfg; build-vm's probe asserts the first, this asserts the
# second while the cause is still on screen.
sudo grep -q 'modprobe.blacklist=amdgpu' /boot/grub/grub.cfg

# --- 6. caches, docs, logs -----------------------------------------------
#
# The path-excludes are for anything a consumer installs later; the rm is for
# what is already here.  Both, because either alone leaves most of it.
sudo tee /etc/dpkg/dpkg.cfg.d/01-slim-no-docs > /dev/null <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/lintian/*
path-include /usr/share/doc/*/copyright
EOF
sudo rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
    /usr/share/lintian /usr/share/help
# Keep English; the rest is a few hundred MB of translations for a guest whose
# entire user interface is an SSH session from a CI job.
sudo find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
    ! -name 'en*' -exec rm -rf {} +

${APT} clean
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    /var/tmp/* /tmp/* /home/"${USERNAME}"/.cache
sudo journalctl --rotate --vacuum-size=1M 2>/dev/null || true
sudo rm -rf /var/log/journal/* /var/lib/systemd/coredump/*
sudo find /var/log -type f -exec truncate -s 0 {} +

# --- 7. the record, and the discard --------------------------------------
#
# What was taken out, where a consumer inside the guest can read it.  This is
# the file to check before assuming a guest can build something: the flavour
# name says "slim", but the detail of what that meant on the day it was built
# lives here.
USED_AFTER=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
sudo tee /etc/slim-trim.json > /dev/null <<EOF
{
  "flavour": "${FLAVOUR}",
  "trim": "slim.sh",
  "in_guest_builds": false,
  "cloud_init": "disabled",
  "booted_kernel": "${KVER}",
  "kernels_installed": 1,
  "amdgpu_dkms_package": "${AMDGPU_PKG}",
  "amdgpu_dkms_firmware_package": "${FW_PKG}",
  "amdgpu_module_version": "${AMDGPU_MODVER}",
  "amdgpu_module_source_removed": true,
  "rocm_path": "${ROCM_PATH}",
  "rocm_subtrees_removed": [${ROCM_DELETED}],
  "linux_firmware_removed": true,
  "snapd_removed": true,
  "root_used_mib_before": ${USED_BEFORE},
  "root_used_mib_after": ${USED_AFTER}
}
EOF
sudo chmod 0644 /etc/slim-trim.json
cat /etc/slim-trim.json

# Appended to the note the provision script already wrote, rather than a second
# file: someone who has just logged in reads one thing, and what it says about
# the two devices is still true.
tee -a "/home/${USERNAME}/WELCOME.md" > /dev/null <<EOF

## This is the slim guest

Built from the same recipe as \`ernic-rocjitsu\` and then trimmed by
\`trim/slim.sh\`. The kernel, the patched \`amdgpu\`, the firmware and the ionic
half are identical. What is gone:

- **The toolchain.** No gcc, no cmake, no kernel headers, no DKMS. This guest
  cannot build \`ionic-ernic\`, or anything else. Use the fat
  \`ernic-rocjitsu\` flavour for a lane that compiles in-guest.
- **The amdgpu DKMS source.** The patched module is installed and is what
  \`modprobe\` picks; it cannot be rebuilt here, so do not install a kernel.
- **ROCm's LLVM and headers.** The HIP runtime is here; \`hipcc\` is not.
- **cloud-init is disabled.** No seed ISO, no userdata, no key injection at
  launch -- log in as \`${USERNAME}\` with the published keypair.
- linux-firmware, snapd, docs, man pages and every apt cache.

\`/etc/slim-trim.json\` is the machine-readable version of this list.
EOF
chmod 0644 "/home/${USERNAME}/WELCOME.md"

echo "root filesystem used: ${USED_BEFORE} -> ${USED_AFTER} MiB"

# And give the freed space back to the qcow2.  probe-guest attaches the disk
# with discard=unmap, so this reaches the image file rather than stopping at
# the guest filesystem; build-vm's convert afterwards is what rewrites it
# compactly.
sudo fstrim -av
