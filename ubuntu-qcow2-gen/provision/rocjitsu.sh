# shellcheck shell=bash
#
# In-guest provisioning for the "rocjitsu" flavour, run by build-vm.sh in a
# PROBE_PERSIST boot after cloud-init.  Everything here is something
# cloud-init's package list cannot express: two third-party apt repositories,
# a patched DKMS source, and a module built against the booted kernel.
#
# Appended to a preamble that sets "set -eu" and the few build-side values
# below, so any failing command fails the image build.  Runs as the guest
# user; root comes from sudo, which is the contract every flavour has.
#
# Derived from qemu-minimal's ansible/playbooks/vm-rocjitsu.yml (the recipe
# that produced the working rocjitsu guest by hand) and rocm-xio's
# scripts/test/ansible/vm-rocjitsu-nvme.yml.  Two deliberate omissions, both
# consumer-specific and both left in rocm-xio's runtime playbook:
#
#   * ip_discovery.bin, which "rj-ip-discovery gfx1250" generates per-config
#     and must match the rocjitsu pin the *consumer* runs, not this image's.
#   * gfx1250 firmware.  See the note above the module build below.
#
# RELEASE, AMDGPU_DRIVER_VERSION and USERNAME come from the preamble.

echo "=== rocjitsu guest provisioning ==="
echo "release: ${RELEASE}  amdgpu driver: ${AMDGPU_DRIVER_VERSION}"

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
# universe copies win and the ROCm runtime is subtly broken -- the same pin
# rocm-xio and qemu-minimal both carry.
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

# Two repositories, versioned independently of each other: ROCm userspace on
# repo.amd.com (TheRock, versionless "stable"), the kernel driver on
# repo.radeon.com under an explicit version.  The driver tree publishes a
# different set of suites per version -- "latest" is jammy and noble only,
# 31.50 is the first with resolute -- and apt reports a missing suite as a
# generic 404 several steps later, so check for it here where the version and
# the codename can both be named in the message.
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

# The minimal ROCm set rocm-xio asks for: enough for rocminfo, the HIP runtime
# and linking, without the full amdrocm meta and its multi-gigabyte tail.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libstdc++-14-dev \
    amdrocm-runtime-dev \
    amdrocm-blas-dev

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
sudo update-pciids || true

# amdgpu must not autoload.  It has to be modprobed by hand with the emulation
# parameters once the vfio-user server is serving, and an autoloaded copy that
# already bound the device makes that impossible: the in-tree module's modprobe
# then returns 0 without rebinding, and unloading the DKMS one has been seen to
# GPF in kgd2kfd_device_exit.  The modprobe.d file covers udev and hand
# modprobes; the cmdline covers a load from the initramfs, which runs before
# any of /etc/modprobe.d is necessarily in scope.
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

# The kernel, and the ordering the whole flavour turns on.  It differs by
# release because the driver does:
#
#   resolute -- amdgpu-dkms 7.1.3 from the 31.50 tree is a 26.04 package that
#     builds against 7.0, so the ordinary order works and is the one wanted:
#     install the kernel and its headers first, then let the DKMS postinst
#     build for every installed kernel including the 7.0 the guest boots.  That
#     module is the driver that loads, and it is the one with GC 12.1.0 and the
#     UMSCH HW IP enumeration the emulated gfx1250 needs.
#
#   noble -- amdgpu-dkms there is a ~24.04 package whose kcl layer does not
#     compile against 7.0 at all, and its postinst builds for every kernel with
#     headers on disk rather than for the running one.  So it must be installed
#     *before* the HWE kernel puts 7.0 headers there, leaving a 6.8 module that
#     cannot load and an in-tree 7.0 driver that rejects the device.  Kept
#     working, not recommended: this is why the published flavour is resolute.
#
# DKMS reports only "consult make.log", and the guest is discarded when the
# build fails, so surface the tail of it while it still exists.
case "${RELEASE}" in
    resolute) HWE_META=linux-generic-hwe-26.04 ;;
    noble)    HWE_META=linux-generic-hwe-24.04 ;;
    *)
        echo "Error: rocjitsu provisioning has no kernel plan for ${RELEASE}" >&2
        exit 1
        ;;
esac

install_hwe_kernel() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "${HWE_META}" "${HWE_META/linux-generic/linux-headers-generic}"
    HWE_KVER=$(dpkg-query -W -f='${Depends}' "${HWE_META/linux-generic/linux-image-generic}" |
        sed 's/.*\(linux-image-[0-9][^ ,]*\).*/\1/' | sed 's/linux-image-//')
    test -n "${HWE_KVER}"
    test -e "/boot/vmlinuz-${HWE_KVER}"
    echo "HWE kernel installed: ${HWE_KVER} (this boot is still $(uname -r))"
}

install_amdgpu_dkms() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y amdgpu-dkms || {
        sudo tail -n 60 /var/lib/dkms/amdgpu/*/build/make.log || true
        exit 1
    }
}

if [ "${RELEASE}" = noble ]; then
    install_amdgpu_dkms
else
    install_hwe_kernel
    install_amdgpu_dkms
fi

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

# Rebuild from the patched source.  On resolute the kernel that matters is the
# HWE one the guest reboots into, not the one this script runs on, and both have
# headers by now -- so build for both and let the boot pick.  On noble only the
# running 6.8 can be built for at all, and what that leaves behind is a patched
# source tree plus a module that never loads.
VER=$(dkms status amdgpu | awk -F'[,/]' 'NR==1{gsub(/ /,"",$2); print $2}')
test -n "${VER}"
DKMS_KVERS="$(uname -r)"
if [ "${RELEASE}" != noble ] && [ "${HWE_KVER}" != "$(uname -r)" ]; then
    DKMS_KVERS="${DKMS_KVERS} ${HWE_KVER}"
fi
for kver in ${DKMS_KVERS}; do
    test -e "/lib/modules/${kver}/build"
    sudo dkms build "amdgpu/${VER}" -k "${kver}" --force || {
        sudo tail -n 60 /var/lib/dkms/amdgpu/*/build/make.log || true
        exit 1
    }
    sudo dkms install "amdgpu/${VER}" -k "${kver}" --force
done

if [ "${RELEASE}" = noble ]; then
    # Installing a kernel runs dkms_autoinstaller from
    # /etc/kernel/postinst.d/dkms, which will try to build amdgpu for 7.0 and
    # fail -- and a failing postinst hook leaves linux-image-7.0.0-*
    # unconfigured.  This flag file is the autoinstaller's own documented escape
    # hatch: still attempt the build, but do not propagate the error.  Not
    # wanted on resolute, where a failing amdgpu build for a new kernel is a
    # real regression and should stop the install that caused it.
    sudo install -d -m 0755 /etc/dkms
    sudo touch /etc/dkms/no-autoinstall-errors

    # The HWE kernel, installed but NOT booted yet -- this script runs on the
    # cloud image's 6.8 and the guest is rebooted after it, so the published
    # image comes up on 7.0.0-31-generic.  It is installed last here precisely
    # so amdgpu-dkms's postinst never saw its headers.
    install_hwe_kernel
fi

sudo update-grub
# The grub.d snippet is only worth anything if it reached the generated config:
# a menuentry without it means the next boot autoloads amdgpu from the
# initramfs, and the probe boot is where that has to be caught.
sudo grep -q 'modprobe.blacklist=amdgpu' /boot/grub/grub.cfg

# gfx1250 firmware arrives with the driver, not by being copied in: amdgpu-dkms
# Depends on amdgpu-dkms-firmware, and from the 31.60 tree that package ships
# real gc_12_1_0 and sdma_7_1_0 blobs into /lib/firmware/updates/amdgpu.  That
# is the pairing upstream's qemu-vfio.md asks for -- firmware from the same
# public driver release as the guest's amdgpu.ko -- and it is the reason this
# flavour is pinned to 31.60 rather than 31.50, whose firmware package had 683
# files and not one of these.
#
# Asserted rather than assumed.  A driver tree that stops shipping them takes
# the guest back to needing a full stub set, and the place to find that out is
# here, not in the emulated device's early init.
FW_DIR=/lib/firmware/updates/amdgpu
for fw in gc_12_1_0_mec.bin gc_12_1_0_mec_1.bin gc_12_1_0_rlc.bin \
          gc_12_1_0_rlc_1.bin gc_12_1_0_uni_mes.bin sdma_7_1_0.bin; do
    if [ ! -s "${FW_DIR}/${fw}" ] && [ ! -s "${FW_DIR}/${fw}.xz" ]; then
        echo "Error: amdgpu-dkms-firmware ${AMDGPU_DRIVER_VERSION} did not" \
             "install ${fw}; this flavour assumes it does" >&2
        exit 1
    fi
done
FW_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms-firmware)
echo "gfx1250 firmware from amdgpu-dkms-firmware ${FW_PKG}:"
for fw in "${FW_DIR}"/gc_12_1_0* "${FW_DIR}"/sdma_7_1_0*; do
    [ -e "${fw}" ] && echo "  $(basename "${fw}")"
done

# What this image is, recorded where a consumer inside the guest can read it.
# vm-info.json stays flavour-agnostic; this is the flavour's own record, and
# the driver version is the thing a consumer most needs to compare against.
AMDGPU_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms)
ROCM_PKG=$(dpkg-query -W -f='${Version}' amdrocm-runtime-dev)
if [ "${RELEASE}" = noble ]; then
    RUNTIME_DRIVER="in-tree amdgpu from the booted HWE kernel; the DKMS module is for $(uname -r) and cannot load"
else
    RUNTIME_DRIVER="amdgpu-dkms ${AMDGPU_PKG}, built for the booted kernel ${HWE_KVER}"
fi
sudo tee /etc/rocjitsu-guest.json > /dev/null <<EOF
{
  "amdgpu_driver_repo_version": "${AMDGPU_DRIVER_VERSION}",
  "amdgpu_dkms_version": "${AMDGPU_PKG}",
  "amdgpu_dkms_module": "${VER}",
  "amdgpu_dkms_built_for_kernels": "${DKMS_KVERS}",
  "booted_kernel": "${HWE_KVER}",
  "amdrocm_runtime_dev_version": "${ROCM_PKG}",
  "rocm_stream": "therock",
  "kfd_atomics_patched": true,
  "kfd_atomics_patch_applies_to": "amdgpu-dkms source and the module built from it",
  "runtime_driver": "${RUNTIME_DRIVER}",
  "amdgpu_autoload_blacklisted": true,
  "amdgpu_blacklisted_on_cmdline": true,
  "amdgpu_dkms_firmware_version": "${FW_PKG}",
  "gfx1250_firmware": "packaged",
  "gfx1250_firmware_dir": "${FW_DIR}",
  "gfx1250_firmware_missing": ["gc_12_1_0_imu.bin"],
  "gfx1250_firmware_missing_source": "vfio_guest_firmware.py --set gap, from the rocjitsu image the consumer runs",
  "ip_discovery_bin": false
}
EOF
cat /etc/rocjitsu-guest.json
