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
# repo.radeon.com under an explicit version.  The driver repo publishes no
# suite for 26.04, which is why this flavour pins release: noble in images.yml.
sudo tee /etc/apt/sources.list.d/rocm.sources > /dev/null <<EOF
Types: deb
URIs: https://stable.repo.amd.com/rocm/${THEROCK_PATH}
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg

Types: deb
URIs: https://repo.radeon.com/amdgpu/${AMDGPU_DRIVER_VERSION}/ubuntu
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
# already bound the device makes that impossible.
printf 'blacklist amdgpu\n' |
    sudo tee /etc/modprobe.d/amdgpu-blacklist.conf > /dev/null

# amdgpu-dkms FIRST, while the cloud image's 6.8 headers are the only ones
# installed.  Its postinst does not build for the running kernel, it builds for
# every kernel that has headers -- so installing the HWE kernel before this (as
# qemu-minimal's playbook and the rocm_setup role both do) puts 7.0 headers on
# disk and the postinst dies on them: amdgpu-dkms is a ~24.04 package whose kcl
# layer does not compile against 7.0 at all.  Reversing the two is the one place
# this flavour deviates from that playbook, and it is why the DKMS module here
# exists while qemu-minimal's guest comes up without one.
#
# DKMS reports only "consult make.log", and the guest is discarded when the
# build fails, so surface the tail of it while it still exists.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y amdgpu-dkms || {
    sudo tail -n 60 /var/lib/dkms/amdgpu/*/build/make.log || true
    exit 1
}

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

# Rebuild against the *running* 6.8 kernel, which is deliberately NOT the
# kernel the published image boots. The DKMS driver cannot be built for 7.0 at
# all, so what this leaves behind is a patched source tree plus a 6.8 module --
# useful to a consumer who wants to build from it, not the driver that loads.
VER=$(dkms status amdgpu | awk -F'[,/]' 'NR==1{gsub(/ /,"",$2); print $2}')
test -n "${VER}"
sudo dkms build "amdgpu/${VER}" -k "$(uname -r)" --force || {
    sudo tail -n 60 /var/lib/dkms/amdgpu/*/build/make.log || true
    exit 1
}
sudo dkms install "amdgpu/${VER}" -k "$(uname -r)" --force

# Installing a kernel runs dkms_autoinstaller from /etc/kernel/postinst.d/dkms,
# which will try to build amdgpu for 7.0 and fail -- and a failing postinst hook
# leaves linux-image-7.0.0-* unconfigured.  This flag file is the autoinstaller's
# own documented escape hatch: still attempt the build, but do not propagate the
# error.  Left in the published image on purpose, so a consumer installing a
# later kernel gets the module if it builds and a working kernel if it does not.
sudo install -d -m 0755 /etc/dkms
sudo touch /etc/dkms/no-autoinstall-errors

# The HWE kernel, installed but NOT booted yet -- this script runs on the cloud
# image's 6.8 and the guest is rebooted after it, so the published image comes
# up on 7.0.0-31-generic.  That is what the emulated device needs: the in-tree
# amdgpu in 7.0 is the first one carrying GC 12.1.0, and it names all seven
# gc_12_1_0/sdma_7_1_0 firmware blobs that amdgpu-dkms names none of.  The DKMS
# module built above is for 6.8 and is deliberately not the driver that loads.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-generic-hwe-24.04 \
    linux-headers-generic-hwe-24.04
HWE_KVER=$(dpkg-query -W -f='${Depends}' linux-image-generic-hwe-24.04 |
    sed 's/.*\(linux-image-[0-9][^ ,]*\).*/\1/' | sed 's/linux-image-//')
test -n "${HWE_KVER}"
test -e "/boot/vmlinuz-${HWE_KVER}"
echo "HWE kernel installed: ${HWE_KVER} (this boot is still $(uname -r))"

# What this image is, recorded where a consumer inside the guest can read it.
# vm-info.json stays flavour-agnostic; this is the flavour's own record, and
# the driver version is the thing a consumer most needs to compare against.
AMDGPU_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms)
ROCM_PKG=$(dpkg-query -W -f='${Version}' amdrocm-runtime-dev)
sudo tee /etc/rocjitsu-guest.json > /dev/null <<EOF
{
  "amdgpu_driver_repo_version": "${AMDGPU_DRIVER_VERSION}",
  "amdgpu_dkms_version": "${AMDGPU_PKG}",
  "amdgpu_dkms_module": "${VER}",
  "amdgpu_dkms_built_for_kernel": "$(uname -r)",
  "booted_kernel": "${HWE_KVER}",
  "amdrocm_runtime_dev_version": "${ROCM_PKG}",
  "rocm_stream": "therock",
  "kfd_atomics_patched": true,
  "kfd_atomics_patch_applies_to": "amdgpu-dkms source only, not the in-tree driver",
  "runtime_driver": "in-tree amdgpu from the booted HWE kernel",
  "amdgpu_autoload_blacklisted": true,
  "gfx1250_firmware": false,
  "ip_discovery_bin": false
}
EOF
cat /etc/rocjitsu-guest.json
