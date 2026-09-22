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
# RELEASE, AMDGPU_DRIVER_VERSION, RDMA_CORE_VERSION and USERNAME come from the
# preamble; the patches and the firmware generator arrive at /tmp/payload.

echo "=== ernic-rocjitsu guest provisioning ==="
echo "release: ${RELEASE}  amdgpu driver: ${AMDGPU_DRIVER_VERSION}"
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

# amdgpu-dkms, installed for its *source* -- the postinst's own build cannot
# succeed here.  It builds the unpatched tree against the 7.2.4 headers, that
# fails, and without this the failure propagates through run-parts into dpkg
# and leaves the package unconfigured.  This flag file is the dkms
# autoinstaller's own documented escape hatch: still attempt the build, but do
# not propagate the error.  The build that matters happens below, from the
# patched source, and is not allowed to fail.
sudo install -d -m 0755 /etc/dkms
sudo touch /etc/dkms/no-autoinstall-errors

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
rm -rf /tmp/fw-gap
FW_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms-firmware)
echo "gfx1250 firmware: packaged from amdgpu-dkms-firmware ${FW_PKG}, plus" \
     "generated ${GENERATED}"

# /dev/kfd and /dev/dri/render* are root:render 0660.  A login user in neither
# render nor video gets a HIP runtime that enumerates no agent at all and a
# hipMalloc returning hipErrorNoDevice, three lines below a perfectly healthy
# KFD node in the same log -- an expensive thing to debug, and a one-line thing
# to prevent.
sudo usermod -aG render,video "${USERNAME}"

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
ROCM_PKG=$(dpkg-query -W -f='${Version}' amdrocm-runtime-dev)
sudo tee /etc/ernic-rocjitsu-guest.json > /dev/null <<EOF
{
  "booted_kernel": "${KVER}",
  "amdgpu_driver_repo_version": "${AMDGPU_DRIVER_VERSION}",
  "amdgpu_dkms_version": "${AMDGPU_PKG}",
  "amdgpu_dkms_module": "${VER}",
  "amdgpu_dkms_built_for_kernels": "${KVER}",
  "amdrocm_runtime_dev_version": "${ROCM_PKG}",
  "rocm_stream": "therock",
  "kfd_atomics_patched": true,
  "amdgpu_patches": [${PATCHES}],
  "kfd_ptrace_gate_reviewed": false,
  "runtime_driver": "amdgpu-dkms ${AMDGPU_PKG}, built for the booted kernel ${KVER}",
  "amdgpu_autoload_blacklisted": true,
  "amdgpu_blacklisted_on_cmdline": true,
  "amdgpu_dkms_firmware_version": "${FW_PKG}",
  "gfx1250_firmware": "packaged + generated gap set",
  "gfx1250_firmware_dir": "${FW_DIR}",
  "gfx1250_firmware_generated": "${GENERATED}",
  "ip_discovery_bin": false,
  "ip_discovery_bin_source": "rj-ip-discovery gfx1250, from the rocjitsu image the consumer runs",
  "render_video_groups": true,
  "rdma_core_version": "${INSTALLED}",
  "rdma_driver": "in-tree ionic_rdma from the booted kernel; ionic-ernic is a DKMS build the consumer does"
}
EOF
cat /etc/ernic-rocjitsu-guest.json
