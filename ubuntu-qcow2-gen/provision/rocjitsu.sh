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

# The rest of the patch set, from assets/shared/patches/amdgpu/ by way of
# /tmp/payload.  Today that is the RAS VBIOS guard and nothing else:
#
#   rocjitsu serves no option ROM (rombar=0), so adev->mode_info.atom_context is
#   NULL.  amdgpu_ras_init queries RAS capabilities from the VBIOS anyway and
#   amdgpu_ras_query_ras_capablity_from_vbios() dereferences atom_context
#   unconditionally, so the probe oopses in amdgpu_atom_parse_data_header+0x9.
#
# It is needed on every kernel, not just 7.2, and it was missing here for as
# long as this flavour has existed: the patch lived only in qemu-minimal's
# vm-rocjitsu.yml, which this flavour does not run.  A consumer who built the
# guest from the playbook got it and a consumer who pulled the published qcow2
# did not, which is the kind of difference that costs a day.
#
# Same source tree as the atomics patch above, and for the same reason: what is
# patched is what a later "dkms autoinstall" rebuilds from.
if [ ! -d /tmp/payload/patches/amdgpu ]; then
    echo "Error: no amdgpu patches at /tmp/payload/patches/amdgpu; the guest" \
         "would boot a driver that oopses on probe under rocjitsu" >&2
    exit 1
fi
AMDGPU_SRC=$(ls -d /usr/src/amdgpu-* | tail -1)
PATCHES=""
for p in /tmp/payload/patches/amdgpu/*.patch; do
    echo "applying $(basename "${p}")"
    sudo patch -p1 -d "${AMDGPU_SRC}" --no-backup-if-mismatch < "${p}"
    PATCHES="${PATCHES}${PATCHES:+,}\"$(basename "${p}"):$(sha256sum "${p}" |
        cut -c1-16)\""
done
test -n "${PATCHES}"

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

# /dev/kfd and /dev/dri/render* are root:render 0660.  A login user in neither
# render nor video gets a HIP runtime that enumerates no agent at all and a
# hipMalloc returning hipErrorNoDevice, three lines below a perfectly healthy
# KFD node in the same log -- an expensive thing to debug, and a one-line thing
# to prevent.  Consumers working around it by running their payload under sudo
# are unaffected; this only means they no longer have to.
sudo usermod -aG render,video "${USERNAME}"

# The probe helper, offered rather than imposed.  Nothing in the image runs it,
# amdgpu stays blacklisted, and a consumer who owns the parameters can ignore
# the file -- rocm-xio's original request put it on the "do not want" list and
# that stays true of the *policy*.  What changed is the cost of not shipping
# anything: ip_block_mask and vramlimit are both wrong in upstream's
# qemu-vfio.md in ways that present as an oops in the command processor and as
# a dispatch that never returns, and the corrected values belong with the
# driver build rather than with whoever happens to call it.
#
# It is also what scripts/perf-harness.sh invokes, so a guest without it fails
# this repository's own integration lane.
sudo install -m 0755 /tmp/payload/amdgpu-probe /usr/local/bin/amdgpu-probe
bash -n /usr/local/bin/amdgpu-probe

# fio with the libhipfile ioengine, so a consumer can measure GPU-side I/O
# against an emulated NVMe controller from inside the guest.
#
# A source build rather than the distro package, because the engine is not in
# any fio release: it landed on master (67256d4e, 2026-05-08) and Ubuntu's fio
# therefore has no libhipfile at all.  FIO_COMMIT is pinned to the same commit
# ubuntu-cuda-rocm-fio builds, so a guest number and a container number are
# from the same fio and can be put on the same axis.
#
# --enable-libhipfile makes the probe hard-fail instead of quietly dropping
# the engine, which is the failure mode worth spending a build on catching:
# a silently engine-less fio still runs, still prints a bandwidth, and the
# number means something entirely different.
#
# Unlike the container build there is no CUDA here and none is wanted, so
# nothing links libcuda and no cuda-compat shim is needed.  --disable-native
# for the same reason that image gives: the qcow2 is published once and booted
# on whatever host a consumer has, so a binary built for this builder's ISA
# would SIGILL on a narrower one.
if [ -n "${FIO_COMMIT:-}" ]; then
    echo "=== fio ${FIO_COMMIT} with the libhipfile ioengine ==="
    # hipFile ships only in the therock stream, which is the stream this
    # flavour installs above -- so a failure here is a package set that moved,
    # not a configuration choice, and it should say so.
    if ! apt-cache show amdrocm-hipfile-dev > /dev/null 2>&1; then
        echo "Error: amdrocm-hipfile-dev is not available from the therock" \
             "repository configured above; fio cannot be built with" \
             "libhipfile support" >&2
        exit 1
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends amdrocm-hipfile-dev
    sudo ldconfig

    # The therock layout again: hipcc and the hipFile headers are under a
    # versioned component directory, so ROCM_PATH is found rather than assumed.
    ROCM_PATH=""
    for d in /opt/rocm /opt/rocm/*; do
        [ -e "${d}/include/hipfile/hipfile.h" ] && ROCM_PATH="${d}"
    done
    if [ -z "${ROCM_PATH}" ]; then
        for d in /opt/rocm /opt/rocm/*; do
            [ -d "${d}/lib" ] && ROCM_PATH="${d}"
        done
    fi
    export ROCM_PATH
    echo "ROCM_PATH for the fio build: ${ROCM_PATH}"

    rm -rf /tmp/fio
    git init /tmp/fio
    git -C /tmp/fio remote add origin https://github.com/axboe/fio.git
    git -C /tmp/fio fetch --depth 1 origin "${FIO_COMMIT}"
    git -C /tmp/fio checkout FETCH_HEAD
    (
        cd /tmp/fio || exit 1
        ./configure --disable-native --enable-libhipfile
        make -j"$(nproc)"
        sudo make install prefix=/usr/local
    )
    git -C /tmp/fio rev-parse HEAD |
        sudo tee /usr/local/share/fio-commit.txt > /dev/null

    # Assert the engine is actually there before the tree is thrown away.  A
    # build that dropped it is recoverable here and is a mystery later.
    hash -r
    fio --enghelp | sudo tee /usr/local/share/fio-engines.txt > /dev/null
    grep -qE '^[[:space:]]*libhipfile$' /usr/local/share/fio-engines.txt
    grep -qE '^[[:space:]]*libaio$' /usr/local/share/fio-engines.txt
    fio --enghelp=libhipfile |
        sudo tee /usr/local/share/fio-libhipfile-help.txt > /dev/null
    # Asynchronous submission (hipfile_mode) exists only on the ROCm fork
    # branch, not on axboe master.  Record which build this is once, here, so
    # nothing has to re-derive it from engine help at run time.
    if grep -q 'hipfile_mode' /usr/local/share/fio-libhipfile-help.txt; then
        echo yes | sudo tee /usr/local/share/fio-hipfile-async.txt > /dev/null
    else
        echo no | sudo tee /usr/local/share/fio-hipfile-async.txt > /dev/null
    fi
    FIO_VERSION=$(fio --version)
    rm -rf /tmp/fio
    echo "installed ${FIO_VERSION} with libhipfile"
else
    echo "note: FIO_COMMIT unset -- no fio in this guest"
    FIO_VERSION=""
fi

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
  "amdgpu_patches": [${PATCHES}],
  "runtime_driver": "${RUNTIME_DRIVER}",
  "amdgpu_autoload_blacklisted": true,
  "amdgpu_blacklisted_on_cmdline": true,
  "amdgpu_probe_helper": "/usr/local/bin/amdgpu-probe",
  "render_video_groups": true,
  "amdgpu_dkms_firmware_version": "${FW_PKG}",
  "gfx1250_firmware": "packaged",
  "gfx1250_firmware_dir": "${FW_DIR}",
  "gfx1250_firmware_missing": ["gc_12_1_0_imu.bin"],
  "gfx1250_firmware_missing_source": "vfio_guest_firmware.py --set gap, from the rocjitsu image the consumer runs",
  "ip_discovery_bin": false,
  "fio_commit": "${FIO_COMMIT:-}",
  "fio_version": "${FIO_VERSION}",
  "fio_libhipfile": $([ -n "${FIO_VERSION}" ] && echo true || echo false),
  "fio_hipfile_async": "$(cat /usr/local/share/fio-hipfile-async.txt 2>/dev/null || echo unknown)",
  "rdma_driver": "none -- rdma-core userspace only; ionic-ernic is a DKMS build the consumer does"
}
EOF
cat /etc/rocjitsu-guest.json

# The same facts as prose, in the first place someone looks.  /etc/*-guest.json
# is for a script; this is for the person who has just SSH'd in and does not
# know that the GPU will not appear until they start a vfio-user server, or
# that a bare "modprobe amdgpu" is the wrong thing to try.  Generated here
# rather than checked in so the versions in it are the resolved ones.
tee "/home/${USERNAME}/WELCOME.md" > /dev/null <<EOF
# rocjitsu guest

Built by batesste-ci-images \`ubuntu-qcow2-gen\`, flavour \`rocjitsu\`, for
running an emulated gfx1250 served by rocjitsu over vfio-user.

    kernel        ${HWE_KVER}
    amdgpu-dkms   ${AMDGPU_PKG}  (module ${VER})
    ROCm          ${ROCM_PKG} from the therock stream
    driver repo   repo.radeon.com/amdgpu/${AMDGPU_DRIVER_VERSION}

## There is no GPU yet, and that is expected

\`amdgpu\` is blacklisted -- in \`/etc/modprobe.d/amdgpu-blacklist.conf\` and
again on the kernel command line -- so nothing loads it at boot. There is no
device to bind to until something outside this guest serves one. \`lspci\` will
not show it, \`/dev/kfd\` will not exist, and \`rocminfo\` is not installed.

## Next steps

1. On the host, start rocjitsu with a vfio-user socket and attach the function
   to this VM. That is the consumer's job, not the image's -- see
   \`ubuntu-rocm-rocjitsu\` in batesste-ci-images.
2. Stage the two firmware files this image deliberately does not carry, because
   they must match the rocjitsu build you are running rather than this disk:
   \`gc_12_1_0_imu.bin\` and \`ip_discovery.bin\`, from
   \`vfio_guest_firmware.py --set gap\` and \`rj-ip-discovery gfx1250\`. Install
   them into \`/lib/firmware/amdgpu/\`. Everything else is already here, in
   ${FW_DIR} -- do not overwrite it.
3. Load the driver:

       sudo amdgpu-probe

   That is a convenience wrapper around \`modprobe amdgpu\` with the emulation
   parameters. Read it before you trust it -- two of the values differ from
   upstream's qemu-vfio.md, for reasons written down in the script. You are
   free to ignore it and pass your own.
4. Check it came up:

       ls /sys/bus/pci/drivers/amdgpu/   # a bound BDF
       ls /dev/kfd                       # the KFD node
       sudo dmesg | grep -i amdgpu       # no vcn/jpeg failure

## Things that will waste your time

- **A warm reboot with the device attached does not work.** Cold-boot instead.
- **\`modprobe\` on an already-resident amdgpu silently discards parameters**
  and returns 0. \`amdgpu-probe\` checks for this and refuses; a bare
  \`modprobe\` will not tell you.
- **\`hipMalloc\` returning \`hipErrorNoDevice\` under a healthy KFD node**
  usually means group membership. This image already puts \`${USERNAME}\` in
  \`render\` and \`video\`, so if you see it, check \`id -nG\` first.

## More

- \`/etc/rocjitsu-guest.json\` -- the same facts, machine-readable
- \`/output/vm-info.json\` in the published payload -- release, kernel, commits
- \`ubuntu-qcow2-gen/consumers/rocm-xio-rocjitsu.md\` in batesste-ci-images
EOF
chmod 0644 "/home/${USERNAME}/WELCOME.md"
