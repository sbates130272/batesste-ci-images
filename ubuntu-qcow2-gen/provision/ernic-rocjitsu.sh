# shellcheck shell=bash
#
# In-guest provisioning for the "ernic-rocjitsu" flavour, run by build-vm.sh in
# a PROBE_PERSIST boot after cloud-init and after the mainline kernel layer.
# This is the guest hipObject's two-device lane needs: an emulated ionic RDMA
# NIC served by rocm-ernic *and* an emulated gfx1250 served by rocjitsu, in one
# image, so the lane stops deriving it at the start of every run.
#
# Appended to a preamble that sets "set -eu" and the few build-side values
# below, so any failing command fails the image build.  Runs as the guest user;
# root comes from sudo, which is the contract every flavour has.
#
# Most of the ROCm half is provision/rocjitsu.sh verbatim and the rdma-core
# half is provision/ionic.sh verbatim.  They are duplicated rather than shared:
# both of those flavours are published and consumed today, and the kernel and
# DKMS handling here is different enough from either that factoring the rest
# out would buy less than it risks.
#
# Three things differ from provision/rocjitsu.sh, all of them consequences of
# booting mainline 7.2.4 rather than the release's own kernel:
#
#   * No HWE metapackage.  The kernel that matters is already installed and
#     booted by the time this runs, and pulling linux-generic-hwe-26.04 in
#     would only add a 7.0 for grub to choose between.
#   * amdgpu-dkms's postinst cannot succeed.  It builds the *unpatched* source
#     against the 7.2.4 headers, and that build fails; /etc/dkms/no-autoinstall-errors
#     keeps the failure from leaving the package unconfigured, and the real
#     build happens below from the patched source.
#   * Three more patches, from assets/ernic-rocjitsu/patches/amdgpu/.  DKMS
#     7.1.9 does not build on 7.2.4 as shipped.
#
# RELEASE, AMDGPU_DRIVER_VERSION, ROCM_PATH, ROCM_VERSION, RDMA_CORE_VERSION
# and USERNAME come from the preamble; the patches and the firmware generator arrive at
# /tmp/payload.

echo "=== ernic-rocjitsu guest provisioning ==="
echo "release: ${RELEASE}  amdgpu driver: ${AMDGPU_DRIVER_VERSION}"
echo "rocm path: ${ROCM_PATH}"
echo "rdma-core: ${RDMA_CORE_VERSION}  kernel: $(uname -r)"

# 7.2 is a hard floor and not a preference: ionic_rdma calls ib_umem_get_va, a
# static inline that exists in 7.2.4 and does not exist in 7.0 or 7.1.13.  The
# kernel layer has already run, so this is a statement about what booted.
test "$(printf '7.2\n%s\n' "$(uname -r)" | sort -V | head -1)" = "7.2"

if [ ! -d /tmp/payload/patches/amdgpu ]; then
    echo "Error: no amdgpu patches at /tmp/payload/patches/amdgpu; this" \
         "flavour cannot build amdgpu-dkms against 7.2 without them" >&2
    exit 1
fi

# TheRock publishes one package set per Ubuntu release; repo.radeon.com's
# amdgpu driver repo uses the release codename as the apt suite.  Both are
# read from the guest rather than assumed, so a release the repositories do
# not publish fails here with a name in the message.
. /etc/os-release
case "${VERSION_ID}" in
    24.04) THEROCK_PATH=core/packages/ubuntu2404 ;;
    26.04) THEROCK_PATH=core/packages/ubuntu2604 ;;
    *)
        echo "Error: no TheRock package set for Ubuntu ${VERSION_ID}" >&2
        exit 1
        ;;
esac

# ROCm's packages and Ubuntu universe ship colliding names.  Without this the
# universe copies win and the ROCm runtime is subtly broken.
sudo tee /etc/apt/preferences.d/rocm-no-distro-packages > /dev/null <<'EOF'
Package: rocminfo hipcc rocm-smi-lib libhsakmt1
Pin: release o=Ubuntu
Pin-Priority: -1

Package: libhsa-runtime64-1 libhsa-runtime-dev libamdhip64-*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 5 --retry-connrefused --max-time 120 \
    https://stable.repo.amd.com/rocm/gpg/packages.gpg |
    gpg --dearmor | sudo tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
curl -fsSL --retry 5 --retry-connrefused --max-time 120 \
    https://repo.radeon.com/rocm/rocm.gpg.key |
    gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

# Two repositories, versioned independently: ROCm userspace on repo.amd.com
# (TheRock, versionless "stable"), the kernel driver on repo.radeon.com under
# an explicit version.  The driver tree publishes a different set of suites per
# version, and apt reports a missing suite as a generic 404 several steps
# later, so check for it here where the version and the codename can both be
# named in the message.
DRIVER_URI="https://repo.radeon.com/amdgpu/${AMDGPU_DRIVER_VERSION}/ubuntu"
curl -fsS --retry 3 --retry-connrefused --max-time 60 -o /dev/null \
    "${DRIVER_URI}/dists/${VERSION_CODENAME}/Release" || {
    echo "Error: repo.radeon.com/amdgpu/${AMDGPU_DRIVER_VERSION} publishes no" \
         "${VERSION_CODENAME} suite; pin amdgpu_driver_version to one that does" >&2
    exit 1
}

sudo tee /etc/apt/sources.list.d/rocm.sources > /dev/null <<EOF
Types: deb
URIs: https://stable.repo.amd.com/rocm/${THEROCK_PATH}
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg

Types: deb
URIs: ${DRIVER_URI}
Suites: ${VERSION_CODENAME}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg
EOF

sudo DEBIAN_FRONTEND=noninteractive apt-get update

# The minimal ROCm set: enough for the HIP runtime and linking, without the
# full amdrocm meta and its multi-gigabyte tail.
#
# Named with the component line rather than bare.  The therock suite is
# versionless but carries several lines at once, /opt/rocm is an alternatives
# symlink resolving to exactly one of them, and a bare name follows whichever
# is newest -- so a line appearing upstream installs packages the guest's own
# ROCM_PATH cannot see.
#
# amdsmi is in the set for a reason the other two are not: it is the only
# per-device health and utilisation tool this guest has any way of getting.
# rocm-smi is deprecated upstream and the therock stream ships no package for
# it at all, so a guest without amdsmi has rocminfo -- which enumerates agents
# and reports nothing about them -- and nothing else.  31 MB.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libstdc++-14-dev \
    "amdrocm-runtime-dev${ROCM_VERSION}" \
    "amdrocm-blas-dev${ROCM_VERSION}" \
    "amdrocm-amdsmi${ROCM_VERSION}"

# Distro copies of the same runtime, if anything pulled them in before the pin
# above was in place.  Harmless when absent.
sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    libhsakmt1 libhsa-runtime64-1 libhsa-runtime-dev 2>/dev/null || true

# The therock packages install under a versioned component directory --
# /opt/rocm/core-10.0/lib, not /opt/rocm/lib -- so enumerate what is actually
# there rather than naming the unversioned paths and quietly resolving nothing.
for d in /opt/rocm/lib /opt/rocm/lib64 /opt/rocm/*/lib /opt/rocm/*/lib64; do
    [ -d "${d}" ] && echo "${d}"
done | sudo tee /etc/ld.so.conf.d/rocm.conf > /dev/null
test -s /etc/ld.so.conf.d/rocm.conf
sudo ldconfig

# The linker now resolves ROCm, but a login shell still does not: the therock
# component directory is versioned, so neither rocminfo nor hipcc is on PATH
# and nothing exports ROCM_PATH.  That is reliably the first thing a consumer
# trips over in this guest, and it costs one file to prevent.
#
# Pinned from images.yml (guest_rocm_version) rather than discovered, and
# asserted rather than assumed: the therock stable stream it names moves, and a
# stale pin has to fail the build here rather than bake a dead PATH entry into
# an image that then looks fine until someone logs in.
test -n "${ROCM_PATH}"
if [ ! -d "${ROCM_PATH}" ]; then
    echo "Error: ${ROCM_PATH} does not exist; guest_rocm_version in images.yml" \
         "names a therock component directory this stream no longer ships." >&2
    echo "Present instead:" >&2
    ls -1d /opt/rocm/*/ >&2 2>/dev/null || true
    exit 1
fi
sudo tee /etc/profile.d/rocm.sh > /dev/null <<EOF
export ROCM_PATH=${ROCM_PATH}
export PATH=${ROCM_PATH}/bin:\$PATH
EOF
sudo chmod 0644 /etc/profile.d/rocm.sh

# And the same two values again, somewhere a *non-login* shell can see them.
#
# /etc/profile.d is sourced by login shells only, which is not the shape most
# consumers of this guest actually use: "ssh guest hipcc ..." is non-login and
# non-interactive, so it sources neither /etc/profile nor ~/.bashrc -- the
# stock ~/.bashrc returns early when non-interactive.  Measured on the
# published image, "ssh guest 'echo $PATH'" had no ROCm entry in it while
# "ssh guest 'bash -lc ...'" did.  That covers every CI step, every Ansible
# command/shell task and every systemd unit, each of which otherwise has to
# know to force a login shell.
#
# /etc/environment is read by pam_env, which runs for an SSH session whether
# or not a login shell follows, so it reaches exactly the callers profile.d
# misses.  It is not a shell script -- no expansion, no $PATH reference -- so
# the whole value has to be written out.  Built from the line the image
# already has rather than from a default spelled here, so a release that picks
# a different PATH keeps the one it picked.
ENV_PATH=$(sed -n 's/^PATH="\?\([^"]*\)"\?$/\1/p' /etc/environment | head -1)
if [ -z "${ENV_PATH}" ]; then
    echo "Error: /etc/environment has no PATH line to prepend to; this" \
         "release does not ship the one the cloud image has always had" >&2
    exit 1
fi
# Any existing ROCm entry comes out first, so a re-run cannot stack a second
# copy on the front.
ENV_PATH=$(printf '%s' "${ENV_PATH}" | tr ':' '\n' | grep -v '^/opt/rocm' |
    paste -sd:)
test -n "${ENV_PATH}"
sudo sed -i '/^ROCM_PATH=/d' /etc/environment
sudo sed -i "s|^PATH=.*|PATH=\"${ROCM_PATH}/bin:${ENV_PATH}\"|" /etc/environment
printf 'ROCM_PATH=%s\n' "${ROCM_PATH}" |
    sudo tee -a /etc/environment > /dev/null
grep -q "^PATH=\"${ROCM_PATH}/bin:" /etc/environment

# Versionless /opt/rocm/bin and /opt/rocm/lib.  A great deal of third-party
# tooling and most ROCm documentation spells those paths literally, and the
# therock layout has neither -- there is only ${ROCM_PATH} -- so a consumer
# following any of it finds nothing.  The symlinks also insulate whatever they
# are written into from the version string itself.
#
# Created only where nothing holds the path already: update-alternatives owns
# some of the names directly under /opt/rocm on this stream, and a hand-made
# symlink over an alternatives slot is a conflict that surfaces at the next
# ROCm upgrade rather than here.
for sub in bin lib; do
    if [ -e "/opt/rocm/${sub}" ] || [ -L "/opt/rocm/${sub}" ]; then
        echo "note: /opt/rocm/${sub} exists already, left alone"
    elif update-alternatives --query "rocm-${sub}" > /dev/null 2>&1; then
        echo "note: update-alternatives owns rocm-${sub}, left alone"
    else
        sudo ln -s "${ROCM_PATH}/${sub}" "/opt/rocm/${sub}"
        echo "linked /opt/rocm/${sub} -> ${ROCM_PATH}/${sub}"
    fi
done

# The amdsmi Python bindings, which the package installs under
# ${ROCM_PATH}/share/amd_smi and puts on no import path, so "import amdsmi"
# fails in a guest that has both the library and the CLI.
#
# A .pth in the system site directory rather than PYTHONPATH in the two files
# above: it works for every python3 however the process was started, and it
# cannot shadow anything, because the directory it adds holds the amdsmi
# package and nothing else.
AMDSMI_PY="${ROCM_PATH}/share/amd_smi"
if [ ! -d "${AMDSMI_PY}/amdsmi" ]; then
    echo "Error: amdrocm-amdsmi${ROCM_VERSION} installed no" \
         "${AMDSMI_PY}/amdsmi; the therock stream has moved the bindings" >&2
    exit 1
fi
# Resolved rather than spelled: the system python's site directory is
# /usr/local/lib/pythonX.Y/dist-packages on Ubuntu today, but which of
# sysconfig's schemes answers for it has moved between releases and the
# obvious one-liner can name a directory that does not exist.  Take the first
# candidate that is actually on disk.
PY_SITE=$(python3 - <<'PYEOF'
import os
import site
import sysconfig

for d in [sysconfig.get_paths()["purelib"], *site.getsitepackages()]:
    if os.path.isdir(d):
        print(d)
        break
PYEOF
)
if [ -z "${PY_SITE}" ]; then
    echo "Error: no python3 site directory exists to drop amdsmi.pth into" >&2
    exit 1
fi
printf '%s\n' "${AMDSMI_PY}" | sudo tee "${PY_SITE}/amdsmi.pth" > /dev/null
sudo chmod 0644 "${PY_SITE}/amdsmi.pth"
python3 -c 'import amdsmi'
# The CLI is a symlink into libexec rather than a real binary, so name it
# rather than relying on the bin/ sweep any trim does.  Not run here: this
# guest has no GPU until a vfio-user server provides one, and amd-smi with
# nothing to enumerate is not a useful assertion.
test -x "${ROCM_PATH}/bin/amd-smi"

# The PCI ID database, refreshed rather than taken from the archive.
#
# Not guarded.  rocm-ernic's guest verification asserts from 9e4cb55 that the
# emulated NIC resolves to the official ionic ID and that its subsystem names
# match pci.ids, and the archive's stock database predates that entry -- so a
# swallowed failure here does not cost a cosmetic lspci label, it hands the
# consumer a guest that fails those checks with nothing in this build saying
# why.  update-pciids exits non-zero if it cannot fetch, and under "set -e"
# that is the image build failing where the cause is still visible.
sudo update-pciids

# amdgpu must not autoload.  It has to be modprobed by hand with the emulation
# parameters once the vfio-user server is serving, and an autoloaded copy that
# already bound the device makes that impossible.  The modprobe.d file covers
# udev and hand modprobes; the cmdline covers a load from the initramfs, which
# runs before any of /etc/modprobe.d is necessarily in scope.
printf 'blacklist amdgpu\n' |
    sudo tee /etc/modprobe.d/amdgpu-blacklist.conf > /dev/null
#
# A grub.d snippet rather than an edit to /etc/default/grub: the cloud image
# assigns GRUB_CMDLINE_LINUX_DEFAULT in
# /etc/default/grub.d/50-cloudimg-settings.cfg, which is sourced afterwards and
# overwrites anything the main file set.  99- sorts last, and appends.
sudo install -d -m 0755 /etc/default/grub.d
printf 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} modprobe.blacklist=amdgpu"\n' |
    sudo tee /etc/default/grub.d/99-amdgpu-blacklist.cfg > /dev/null

# And kept out of the initramfs entirely, not merely blacklisted in it.
#
# The two guards above stop amdgpu loading; neither removes it. A module that
# is still in the initramfs is one udev rule or one edited cmdline away from
# binding the device before the vfio-user server is serving, which is the
# failure the blacklist exists to prevent rather than a milder version of it.
# initramfs-tools has no exclude list, so the module is dropped by a hook --
# which runs on every later update-initramfs too, including the ones a DKMS
# build triggers.
#
# The hook has to do two things, and doing only the obvious one is why this
# silently stopped working. resolute's mkinitramfs calls apply_add_modules
# *twice* -- once before the hooks and once after them:
#
#   apply_add_modules                            # modules copied into DESTDIR
#   run_scripts_optional .../hooks               # stock hooks
#   run_scripts_optional ${CONFDIR}/hooks        # this hook
#   apply_add_modules                            # copies the queue again
#
# so deleting the file from DESTDIR is undone a few lines later by the second
# flush. Ubuntu 24.04's mkinitramfs has a single apply_add_modules before the
# local hooks, which is why the delete-only form worked when it was written
# and stopped working when the guest moved to resolute. Dropping the module
# from the pending queue as well is what survives the second flush.
sudo install -d -m 0755 /etc/initramfs-tools/hooks
sudo tee /etc/initramfs-tools/hooks/amdgpu-exclude > /dev/null <<'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "${PREREQ}"; }
case "${1}" in prereqs) prereqs; exit 0 ;; esac
[ -n "${DESTDIR}" ] || exit 0
# The queue, not the staging tree. At the time a ${CONFDIR}/hooks script runs
# the module has not been copied yet -- it is pending in __MODULES_TO_ADD as
# the bare name "amdgpu", and the apply_add_modules *after* the hooks is what
# copies it. A find/-delete here sees nothing and achieves nothing, which is
# how two flavours shipped with amdgpu.ko in every initramfs.
#
# __MODULES_TO_ADD is mkinitramfs' own variable rather than a published
# interface; if a future version renames it this guard does nothing and the
# assert after update-initramfs is what catches it.
if [ -n "${__MODULES_TO_ADD:-}" ] && [ -f "${__MODULES_TO_ADD}" ]; then
    grep -vx 'amdgpu' "${__MODULES_TO_ADD}" > "${__MODULES_TO_ADD}.keep" || true
    mv "${__MODULES_TO_ADD}.keep" "${__MODULES_TO_ADD}"
fi
find "${DESTDIR}" -name 'amdgpu.ko*' -delete
HOOK
sudo chmod 0755 /etc/initramfs-tools/hooks/amdgpu-exclude

# amdgpu-dkms, installed for its *source* -- the postinst's own build cannot
# succeed here.  It builds the unpatched tree against the 7.2.4 headers, that
# fails, and without this the failure propagates through run-parts into dpkg
# and leaves the package unconfigured.  This flag file is the dkms
# autoinstaller's own documented escape hatch: still attempt the build, but do
# not propagate the error.  The build that matters happens below, from the
# patched source, and is not allowed to fail.
sudo install -d -m 0755 /etc/dkms
sudo touch /etc/dkms/no-autoinstall-errors

# Installed for its *source*: everything the postinst builds is discarded a few
# steps below, where the tree is patched and rebuilt. Left alone the postinst
# autoinstalls for every kernel on the disk, and none of it survives the patch
# -- on this flavour it cannot even succeed, which is what
# no-autoinstall-errors above is for.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y amdgpu-dkms || {
    sudo tail -n 60 /var/lib/dkms/amdgpu/*/build/make.log || true
    exit 1
}
# Tolerating a failed postinst build is not the same as tolerating a package
# that never configured: the source tree has to actually be on disk.
dpkg-query -W -f='${Status}' amdgpu-dkms | grep -q '^install ok installed$'

# The emulated device cannot advertise PCIe atomics through the vfio-user PCI
# capability, and KFD refuses a device without them.  Assume support when
# amdgpu_emu_mode is active.  Patching the DKMS *source* rather than the built
# module is what makes this survive a later "dkms autoinstall" on a new kernel.
sudo python3 - <<'PYEOF'
import glob
import sys

srcs = sorted(glob.glob('/usr/src/amdgpu-*'))
if not srcs:
    sys.exit('no amdgpu DKMS source found')
path = srcs[-1] + '/amd/amdkfd/kfd_device.c'
old = ('kfd->pci_atomic_requested = '
       'amdgpu_amdkfd_have_atomics_support(kfd->adev);')
new = ('kfd->pci_atomic_requested = '
       'amdgpu_amdkfd_have_atomics_support(kfd->adev) || '
       '(amdgpu_emu_mode == 1);')
content = open(path).read()
if new in content:
    print('already patched')
    sys.exit(0)
if old not in content:
    sys.exit(f'target string not found in {path}')
open(path, 'w').write(content.replace(old, new, 1))
print(f'patched {path}')
PYEOF

# The three patches DKMS 7.1.9 needs to build on 7.2.4 at all.  Applied in
# sorted order, and their hashes recorded: what a guest was built from has to
# be answerable from inside it, not only from this repo's history.  See
# assets/ernic-rocjitsu/patches/amdgpu/README.md -- 0001 changes a KFD security
# check and is carried unreviewed.
AMDGPU_SRC=$(ls -d /usr/src/amdgpu-* | tail -1)
PATCHES=""
for p in /tmp/payload/patches/amdgpu/*.patch; do
    echo "applying $(basename "${p}")"
    sudo patch -p1 -d "${AMDGPU_SRC}" --no-backup-if-mismatch < "${p}"
    PATCHES="${PATCHES}${PATCHES:+,}\"$(basename "${p}"):$(sha256sum "${p}" |
        cut -c1-16)\""
done

# Rebuild from the patched source, for the booted kernel and no other: the
# mainline .debs are the only headers on disk, and the module that has to load
# is the one for the kernel this guest comes up on.  DKMS reports only "consult
# make.log", and the guest is discarded when the build fails, so surface the
# tail of it while it still exists.
VER=$(dkms status amdgpu | awk -F'[,/]' 'NR==1{gsub(/ /,"",$2); print $2}')
test -n "${VER}"
KVER=$(uname -r)
test -e "/lib/modules/${KVER}/build"
# The postinst's failed attempt leaves a build tree behind that dkms will
# happily reuse; it was made from the unpatched source.
sudo rm -rf /var/lib/dkms/amdgpu/"${VER}"/build
sudo dkms build "amdgpu/${VER}" -k "${KVER}" --force || {
    sudo tail -n 60 /var/lib/dkms/amdgpu/*/build/make.log || true
    exit 1
}
sudo dkms install "amdgpu/${VER}" -k "${KVER}" --force

# The patched module has to be the one modprobe would pick, ahead of the
# in-tree driver.  A DKMS build that succeeded and did not win is the failure
# this flavour exists to prevent.
AMDGPU_KO=$(modinfo -n amdgpu)
case "${AMDGPU_KO}" in
    */updates/dkms/*) ;;
    *)
        echo "Error: modprobe would load ${AMDGPU_KO}, not the DKMS module" >&2
        exit 1
        ;;
esac
echo "amdgpu.ko: ${AMDGPU_KO}"

# Regenerated so the exclude hook above applies to every initramfs on the
# disk, not only to the ones the DKMS build happened to rebuild.
# Autoinstall back on before anything ships. From here the guest behaves as a
# consumer expects: installing a kernel rebuilds the patched amdgpu, which is
# the property the whole patch-the-source approach exists to provide.
sudo update-initramfs -u -k all

# Assert it actually worked, here, where the build can still fail.
#
# This is the line that matters. The hook above reaches into a mkinitramfs
# internal, so it is one upstream rename away from quietly doing nothing --
# which is exactly what happened before, shipping two flavours whose
# initramfs carried amdgpu.ko.zst under updates/dkms/ while the checks said
# otherwise. An assert that runs on every build is worth more than a hook
# that is assumed to work.
#
# Written as an if/exit rather than `! lsinitramfs ... | grep -q ...`: a
# command whose status is inverted with `!` never trips `set -e`, so the
# negated form cannot fail a build no matter what it finds.
for img in /boot/initrd.img-*; do
    [ -e "${img}" ] || continue
    if lsinitramfs "${img}" | grep -qE '(^|/)amdgpu\.ko(\.[a-z]+)?$'; then
        echo "ERROR: amdgpu.ko is present in ${img}" >&2
        echo "       the initramfs exclude hook did not take; see the note" >&2
        echo "       beside /etc/initramfs-tools/hooks/amdgpu-exclude" >&2
        exit 1
    fi
done

sudo update-grub
# The grub.d snippet is only worth anything if it reached the generated config:
# a menuentry without it means the next boot autoloads amdgpu from the
# initramfs, and the probe boot is where that has to be caught.
sudo grep -q 'modprobe.blacklist=amdgpu' /boot/grub/grub.cfg

# Most gfx1250 firmware arrives with the driver: amdgpu-dkms depends on
# amdgpu-dkms-firmware, and from the 31.60 tree that package ships real
# gc_12_1_0 and sdma_7_1_0 blobs into /lib/firmware/updates/amdgpu.  Asserted
# rather than assumed -- a driver tree that stops shipping them takes the guest
# back to needing a full stub set, and the place to find that out is here, not
# in the emulated device's early init.
FW_DIR=/lib/firmware/updates/amdgpu
for fw in gc_12_1_0_mec.bin gc_12_1_0_mec_1.bin gc_12_1_0_rlc.bin \
          gc_12_1_0_rlc_1.bin gc_12_1_0_uni_mes.bin sdma_7_1_0.bin; do
    if [ ! -s "${FW_DIR}/${fw}" ] && [ ! -s "${FW_DIR}/${fw}.xz" ]; then
        echo "Error: amdgpu-dkms-firmware ${AMDGPU_DRIVER_VERSION} did not" \
             "install ${fw}; this flavour assumes it does" >&2
        exit 1
    fi
done

# What no driver release ships, and what this flavour does bake in -- unlike
# the rocjitsu flavour, which leaves the whole gap to its consumer.  These
# three are static fixtures: gc_12_1_0_imu.bin is AMDGPU_UCODE_REQUIRED under
# the amdgpu.fw_load_type=0 the vfio guest boots with, and mes/mes1 are the
# uni_mes builder's bytes under the names amdgpu opens when amdgpu_uni_mes=0.
# None of them depend on which rocjitsu build serves the socket, which is why
# they can live in the image at all.
#
# ip_discovery.bin deliberately does not: it comes from "rj-ip-discovery
# gfx1250" and must match the rocjitsu pin the *consumer* runs, not this
# image's.  --no-ip-discovery is what says so.
#
# --generation gfx1250 rather than --config: no rocjitsu config exists in a
# guest, and naming the generation keeps this independent of the rocjitsu
# container's baked-in config path.
sudo python3 /tmp/payload/vfio-guest-firmware.py \
    --set gap --generation gfx1250 --no-ip-discovery --output /tmp/fw-gap
GENERATED=$(python3 -c \
    'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["files"]))' \
    /tmp/fw-gap/manifest.json)
test -n "${GENERATED}"
sudo install -d -m 0755 "${FW_DIR}"
for fw in ${GENERATED}; do
    # The generator never names a packaged blob in the gap set, so this is an
    # assertion about it rather than a guard: writing a sentinel stub over real
    # microcode is strictly worse than not writing it.
    if [ -e "${FW_DIR}/${fw}" ] || [ -e "${FW_DIR}/${fw}.xz" ]; then
        echo "Error: gap set names ${fw}, which the driver release ships" >&2
        exit 1
    fi
    sudo install -m 0644 "/tmp/fw-gap/${fw}" "${FW_DIR}/${fw}"
done
sudo install -m 0644 /tmp/fw-gap/manifest.json \
    "${FW_DIR}/rocjitsu-gap-manifest.json"
# sudo, because the generator above ran under sudo and its output is root-owned.
# /tmp is sticky, so an unprivileged unlink of a root-owned file there fails
# even though the directory is world-writable -- and "set -e" makes that the end
# of the provisioning boot, 40 minutes in, after the DKMS build.
sudo rm -rf /tmp/fw-gap
# The directory the one firmware file this image does not carry has to be
# staged into.  Created empty and on purpose: nothing installs
# /lib/firmware/amdgpu in this guest -- linux-firmware is not pulled in by
# linux-image-virtual or by the mainline .debs -- so the WELCOME.md
# instruction to stage ip_discovery.bin there lands in a path that does not
# exist, and "mkdir -p" is not the first thing somebody reaches for when a
# driver says it cannot load firmware.
#
# Empty rather than populated.  Whether anything else under that directory is
# needed on this guest is unsettled -- a working guest was produced by copying
# a previous image's whole 672-file tree, which is a wider fix than the single
# missing file the probe failure names -- so this creates the place and does
# not pretend to answer the rest.
sudo install -d -m 0755 /lib/firmware/amdgpu
sudo tee /lib/firmware/amdgpu/README > /dev/null <<'EOF'
Deliberately empty.  Stage ip_discovery.bin here, generated by
"rj-ip-discovery gfx1250" from the same rocjitsu build that serves the
vfio-user socket; it is the one firmware file this image cannot carry,
because it must match the consumer's rocjitsu pin rather than the image's.

The rest of the gfx1250 firmware is in /lib/firmware/updates/amdgpu --
packaged blobs from amdgpu-dkms-firmware plus a generated gap set.  Do not
overwrite it.
EOF
sudo chmod 0644 /lib/firmware/amdgpu/README
FW_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms-firmware)
echo "gfx1250 firmware: packaged from amdgpu-dkms-firmware ${FW_PKG}, plus" \
     "generated ${GENERATED}"

# /dev/kfd and /dev/dri/render* are root:render 0660.  A login user in neither
# render nor video gets a HIP runtime that enumerates no agent at all and a
# hipMalloc returning hipErrorNoDevice, three lines below a perfectly healthy
# KFD node in the same log -- an expensive thing to debug, and a one-line thing
# to prevent.
sudo usermod -aG render,video "${USERNAME}"

# The probe helper, from assets/shared/ -- the same file provision/rocjitsu.sh
# installs, because both flavours build the same driver and the parameters
# belong with the build.  Offered, not imposed: nothing here runs it and amdgpu
# stays blacklisted.  See the note in provision/rocjitsu.sh.
sudo install -m 0755 /tmp/payload/amdgpu-probe /usr/local/bin/amdgpu-probe
bash -n /usr/local/bin/amdgpu-probe

# RDMA pins memory, and this guest's default ceiling is 8192 KB.  Past it
# every ibv_reg_mr() fails with "Cannot allocate memory", and it is reported
# a long way from the cause: UCX surfaces it as a ud_recv_skb mpool failure
# and NIXL's libfabric plugin as "Failed to initialize control request pool
# for rail 0".  Neither says memlock, and the guest this flavour replaced had
# it unlimited, so a consumer moving between them hits it with no clue what
# changed.
#
# Both files, because they cover callers the other cannot.  limits.d is PAM,
# so it reaches an SSH login and anything started from one; a systemd unit
# never goes through PAM's limits and takes DefaultLimitMEMLOCK instead.  A
# consumer running their RDMA binary from a unit file is the case that fails
# with only the first.
sudo install -d -m 0755 /etc/security/limits.d
sudo tee /etc/security/limits.d/99-rdma-memlock.conf > /dev/null <<'EOF'
# Unlimited locked memory for RDMA.  See provision/ernic-rocjitsu.sh in
# batesste-ci-images.
*       soft    memlock     unlimited
*       hard    memlock     unlimited
root    soft    memlock     unlimited
root    hard    memlock     unlimited
EOF
sudo chmod 0644 /etc/security/limits.d/99-rdma-memlock.conf
sudo install -d -m 0755 /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/99-rdma-memlock.conf > /dev/null <<'EOF'
[Manager]
DefaultLimitMEMLOCK=infinity
EOF
sudo chmod 0644 /etc/systemd/system.conf.d/99-rdma-memlock.conf
# Not asserted here: both take effect at the next login and the next boot
# respectively, and this script is running inside the session they do not
# apply to.  checks/ernic-rocjitsu.sh asserts "ulimit -l" in the verification
# boot, which is a fresh login on a rebooted guest -- the shape a consumer
# gets.

# The ionic half.  Nothing is installed: resolute packages rdma-core 61.0, and
# its ibverbs-providers already carries libionic-rdmav59.so -- the userspace
# provider that makes the emulated NIC usable through libibverbs, and the only
# reason rocm-ernic's ernic_guest_setup role builds rdma-core from source at
# all.  The archive supplies it, so this flavour does not overwrite dpkg-owned
# paths under /usr, and needs no holds to defend the result from apt.
if [ -z "${RDMA_CORE_VERSION}" ]; then
    echo "Error: RDMA_CORE_VERSION is empty" >&2
    exit 1
fi

# The pin is an assertion about the release, not an instruction: the stamp has
# to describe what is actually installed, so read that and refuse to stamp
# anything else.
INSTALLED=$(dpkg-query -W -f='${Version}' rdma-core)
if [ "${INSTALLED%%-*}" != "${RDMA_CORE_VERSION}" ]; then
    echo "Error: ${RELEASE} packages rdma-core ${INSTALLED}," \
        "expected ${RDMA_CORE_VERSION}" >&2
    exit 1
fi

# The role's own verification step, run here so a guest missing the provider
# fails this image rather than the consumer.  The provider carries the ABI
# suffix rather than a bare name -- libionic-rdmav59.so at 61.0 -- so match on
# the prefix.
ls /usr/lib/*/libibverbs/libionic*.so

# Format is <version>:<gda-patch-hash>, with the literal string "none" when no
# GDA patches were applied.  The role compares the trimmed contents against a
# value it computes, so both the text and the trailing newline matter.
sudo install -d -m 0755 /usr/local/share/rocm-ernic
printf '%s:none\n' "${RDMA_CORE_VERSION}" |
    sudo tee /usr/local/share/rocm-ernic/provider.stamp > /dev/null
sudo chmod 0644 /usr/local/share/rocm-ernic/provider.stamp

# What this image is, recorded where a consumer inside the guest can read it.
# vm-info.json stays flavour-agnostic; this is the flavour's own record.
AMDGPU_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms)
ROCM_PKG=$(dpkg-query -W -f='${Version}' "amdrocm-runtime-dev${ROCM_VERSION}")
sudo tee /etc/ernic-rocjitsu-guest.json > /dev/null <<EOF
{
  "booted_kernel": "${KVER}",
  "amdgpu_driver_repo_version": "${AMDGPU_DRIVER_VERSION}",
  "amdgpu_dkms_version": "${AMDGPU_PKG}",
  "amdgpu_dkms_module": "${VER}",
  "amdgpu_dkms_built_for_kernels": "${KVER}",
  "amdrocm_runtime_dev_version": "${ROCM_PKG}",
  "rocm_stream": "therock",
  "rocm_path": "${ROCM_PATH}",
  "rocm_on_non_login_path": true,
  "rocm_versionless_symlinks": ["/opt/rocm/bin", "/opt/rocm/lib"],
  "amd_smi": "${ROCM_PATH}/bin/amd-smi",
  "amd_smi_python_bindings": true,
  "rocm_smi": "absent -- deprecated upstream and not packaged in this stream",
  "kfd_atomics_patched": true,
  "amdgpu_patches": [${PATCHES}],
  "kfd_ptrace_gate_reviewed": false,
  "runtime_driver": "amdgpu-dkms ${AMDGPU_PKG}, built for the booted kernel ${KVER}",
  "amdgpu_autoload_blacklisted": true,
  "amdgpu_blacklisted_on_cmdline": true,
  "amdgpu_probe_helper": "/usr/local/bin/amdgpu-probe",
  "amdgpu_dkms_firmware_version": "${FW_PKG}",
  "gfx1250_firmware": "packaged + generated gap set",
  "gfx1250_firmware_dir": "${FW_DIR}",
  "gfx1250_firmware_generated": "${GENERATED}",
  "ip_discovery_bin": false,
  "ip_discovery_bin_source": "rj-ip-discovery gfx1250, from the rocjitsu image the consumer runs",
  "render_video_groups": true,
  "rdma_core_version": "${INSTALLED}",
  "memlock": "unlimited",
  "rdma_driver": "in-tree ionic_rdma from the booted kernel when this script ends; see /etc/ionic-srq.json, written by the post-provision playbook that replaces it with an SRQ-capable build"
}
EOF
cat /etc/ernic-rocjitsu-guest.json

# The same facts as prose, in the first place someone looks.  This guest has
# two emulated devices and neither of them exists at login, which is a
# confusing thing to walk into without a note.
tee "/home/${USERNAME}/WELCOME.md" > /dev/null <<EOF
# ernic-rocjitsu guest

Built by batesste-ci-images \`ubuntu-qcow2-gen\`, flavour \`ernic-rocjitsu\`.
One guest carrying **both** an emulated AMD Pensando ionic RDMA NIC (served by
rocm-ernic) and an emulated gfx1250 (served by rocjitsu), for hipObject's
two-device jobs.

    kernel        ${KVER}  (mainline, from the Ubuntu mainline PPA)
    amdgpu-dkms   ${AMDGPU_PKG}  (module ${VER})
    ROCm          ${ROCM_PKG} from the therock stream
    rdma-core     ${INSTALLED} from the archive

## Neither device exists yet, and that is expected

\`amdgpu\` is blacklisted -- in \`/etc/modprobe.d/\` and again on the kernel
command line -- and \`ionic\`/\`ionic_rdma\` have nothing to bind to. Both
functions are attached from outside the guest by whoever started the vfio-user
servers. \`ibv_devinfo\` reporting no devices and an absent \`/dev/kfd\` are the
correct answers before that happens.

## Next steps

### The GPU half

1. Stage \`ip_discovery.bin\` from \`rj-ip-discovery gfx1250\`, generated by the
   **same rocjitsu build** serving the socket, into \`/lib/firmware/amdgpu/\`.
   It is the one firmware file this image does not carry, for exactly that
   reason. The rest -- including the generated gap set -- is already in
   ${FW_DIR}; do not overwrite it.
2. Load the driver:

       sudo amdgpu-probe

   A convenience wrapper around \`modprobe amdgpu\` with the emulation
   parameters. Read it before trusting it; you are free to pass your own.
3. Check: a bound BDF under \`/sys/bus/pci/drivers/amdgpu/\`, \`/dev/kfd\`
   present, and no vcn/jpeg failure in \`sudo dmesg\`.

### The RDMA half

\`ionic\` and \`ionic_rdma\` are in-tree in ${KVER}, and this image **replaces
both** with an SRQ-capable build: rocm-ernic's \`patches/srq\` on top of the
matching mainline tag, installed as the \`ionic-ernic\` DKMS package into
\`updates/dkms\`, plus rocm-ernic's \`patches/rdma-core\` built into
\`/usr/local\`. \`/etc/ionic-srq.json\` records both pins.

That is not a nicety. Without the series \`max_srq\` is 0, and UCX's
\`rc_verbs\` transport is built on a shared receive queue -- it declines the
device, leaves \`ud_verbs\`, which has no one-sided RDMA READ/WRITE, and
everything above it quietly runs several times slower with nothing in the
failure naming SRQ. Both halves are needed: with only the kernel half the
device advertises an SRQ and \`ibv_create_srq()\` fails \`EOPNOTSUPP\`.

**If you rebuild \`ionic-ernic\` in this guest, pass \`--patches-dir\`
pointing at rocm-ernic's \`patches/srq\`.** A stock rebuild replaces what is
here with a driver that has no SRQ at all, under the same package name, and
the guest goes back to \`max_srq: 0\` with nothing to show it changed.

To check what is loaded, use \`nm\`, not \`strings\`:
\`strings ionic_rdma.ko | grep -i srq\` returns around a dozen hits on a
module with no SRQ support whatsoever -- they are BTF enumerator and
struct-field names. \`nm \$(modinfo -n ionic_rdma) | grep ionic_create_srq\`
is the question actually being asked.

The archive's \`ibverbs-providers\` still carries the unpatched provider and
is untouched, and \`/usr/local/share/rocm-ernic/provider.stamp\` records its
version for \`ernic_guest_setup\` to read; the \`/usr/local\` build simply
wins at run time, because ld.so searches there first.

Expect the device to reach \`PORT_ACTIVE\` / \`LinkUp\` once attached.

## Things that will waste your time

- **This guest needs >= 4 vCPUs.** \`IONIC_EQ_COUNT_MIN\` is 4, and a 2-vCPU
  guest fails inside the ionic driver rather than anywhere obvious.
- **A warm reboot with the rocjitsu function attached does not work.**
  Cold-boot instead.
- **\`modprobe\` on an already-resident amdgpu silently discards parameters**
  and returns 0. \`amdgpu-probe\` refuses in that case; a bare \`modprobe\`
  will not tell you.
- **A bare \`modprobe amdgpu\` is not recoverable without a reboot.** The
  module needs \`emu_mode=1 fw_load_type=0 discovery=2 ip_block_mask=0x7f\`,
  which only \`amdgpu-probe\` supplies; loaded without them it binds nothing,
  and \`rmmod amdgpu\` then **segfaults**. Use \`sudo amdgpu-probe\`, or plan
  on cold-booting the guest.
- **\`ip_discovery.bin\` is the one firmware file this image does not carry**,
  and amdgpu cannot probe without it: the failure is
  \`can't load firmware "amdgpu/ip_discovery.bin"\` followed by
  \`discovery failed: -2\` and \`probe with driver amdgpu failed with error
  -2\`. Generate it with \`rj-ip-discovery gfx1250\` from the *same* rocjitsu
  build serving the socket and stage it into \`/lib/firmware/amdgpu/\`, which
  this image leaves empty for that purpose.
- **Locked memory is unlimited here, deliberately.** If you rebuild this
  guest's limits, keep it: every \`ibv_reg_mr()\` past the 8192 KB default
  fails with "Cannot allocate memory", reported far from the cause -- UCX
  calls it a \`ud_recv_skb\` mpool failure, NIXL's libfabric plugin calls it
  "Failed to initialize control request pool for rail 0". Unprivileged
  \`ib_send_bw\` above about 4 MiB is the same limit wearing a different hat:
  it reports \`Couldn't create CQ\`, and it passes as root because
  \`CAP_IPC_LOCK\` bypasses the rlimit -- note \`ulimit -l\` still *reads*
  8192 under \`sudo\`, so the limit is easy to rule out incorrectly.
- **One of the amdgpu patches in this image is unreviewed.** It changes a KFD
  ptrace check to make the build pass on 7.2. The guest records
  \`"kfd_ptrace_gate_reviewed": false\`. Do not put anything here that you
  would mind a local user reading.

## ROCm is on PATH for non-login shells too

\`ssh guest 'hipcc ...'\` works. That is worth saying because it did not use
to: ROCm was exported from \`/etc/profile.d/rocm.sh\`, which only a *login*
shell sources, so \`ssh guest 'echo \$PATH'\` had no ROCm in it while
\`ssh guest 'bash -lc ...'\` did -- and every CI step, Ansible \`command\` task
and systemd unit landed on the first shape. \`ROCM_PATH\` and the \`bin\` entry
are now in \`/etc/environment\` as well, which \`pam_env\` applies to any SSH
session.

\`/opt/rocm/bin\` and \`/opt/rocm/lib\` exist as symlinks to
\`${ROCM_PATH}\`, so documentation and third-party tooling that spells those
paths literally resolves here.

\`amd-smi\` is installed, with its Python bindings importable as \`amdsmi\`.
\`rocm-smi\` is **not** here and is not coming: it is deprecated upstream and
this ROCm stream ships no package for it. \`rocminfo\` enumerates agents;
\`amd-smi\` is what reports per-device health and utilisation.

## More

- \`/etc/ernic-rocjitsu-guest.json\` -- the same facts, machine-readable,
  including \`amdgpu_patches\` with a hash of each patch applied
- \`ubuntu-qcow2-gen/consumers/hipobject-ernic-rocjitsu.md\` in
  batesste-ci-images
EOF
chmod 0644 "/home/${USERNAME}/WELCOME.md"
