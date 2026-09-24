# shellcheck shell=bash
#
# Assertions run inside the "ernic-rocjitsu" guest during the build's probe
# boot.  Appended to a "set -eu" bash script, so any failing command fails the
# build.
#
# This boot has neither device -- the NIC exists only when a consumer runs
# rocm-ernic and the GPU only when it runs rocjitsu -- so nothing here can
# assert either comes up.  What it can assert is that everything the consumer
# would otherwise have had to install, patch and build at runtime is present
# and in the state it promised.

# The floor the whole flavour turns on.  ionic_rdma calls ib_umem_get_va, a
# static inline that exists in 7.2.4 and does not in 7.0 or 7.1.13, so a guest
# without it fails at compile time in the consumer's job rather than here.
# Compare the whole version tuple, not major-and-minor separately -- "major >= 6
# and minor >= 18" rejects 7.0, which is the most likely way a correct image
# still looks wrong -- and then assert the symbol, not just the number.
test "$(printf '7.2\n%s\n' "$(uname -r)" | sort -V | head -1)" = "7.2"
grep -q ib_umem_get_va /lib/modules/"$(uname -r)"/build/include/rdma/ib_umem.h
. /etc/os-release

# The toolchain and headers, so both out-of-tree modules can be built here:
# ionic-ernic, which the consuming jobs build because building it is what they
# exist to test, and amdgpu, which this image has already built.
command -v gcc make cmake ninja dkms git
test -d /lib/modules/"$(uname -r)"/build
python3 -c 'import docutils'
pkg-config --exists libnl-3.0 libnl-route-3.0 libudev libsystemd

# --- the ionic half ------------------------------------------------------

# The RDMA stack ships with the mainline kernel rather than needing a build.
command -v ibv_devinfo
modinfo ionic_rdma > /dev/null
ldconfig -p | grep -q libibverbs

# providers/ionic, which is what makes the emulated NIC usable through
# libibverbs.  Upstream first shipped it in v61 and resolute packages 61.0, so
# the archive supplies it.  The provider carries the ABI suffix rather than a
# bare name -- libionic-rdmav59.so at 61.0 -- so match on the prefix.
ls /usr/lib/*/libibverbs/libionic*.so
# And it is still the packaged file.  A source build installed over /usr leaves
# this same path in place while orphaning it from dpkg, which is the state this
# flavour deliberately does not create.
dpkg -S /usr/lib/*/libibverbs/libionic*.so > /dev/null

# The stamp ernic_guest_setup reads before deciding to build rdma-core itself.
# No version literal in this file: the stamp has to describe the rdma-core that
# is actually installed, so compare it against dpkg rather than against a copy
# of the pin -- which the pin would satisfy even if the guest carried something
# else entirely.
STAMP=$(cat /usr/local/share/rocm-ernic/provider.stamp)
test "${STAMP#*:}" = none
INSTALLED=$(dpkg-query -W -f='${Version}' rdma-core)
test "${STAMP%%:*}" = "${INSTALLED%%-*}"

# Traffic generators for jobs that exercise the queue pairs.  Name the read and
# write verbs separately: perftest splits across binaries and a partial install
# is the failure worth catching here.
command -v ib_send_bw ib_write_bw ib_read_bw ib_send_lat

# --- the rocjitsu half ---------------------------------------------------

# ROCm userspace, from the therock stream rather than the universe copies
# pinned out in provisioning.  Assert the libraries, not rocminfo: it is not in
# the minimal set, the therock runtime package does not carry it, and the
# distro copy is pinned to never-install.
dpkg-query -W -f='${Status}' amdrocm-runtime-dev |
    grep -q '^install ok installed$'
dpkg-query -W -f='${Status}' amdrocm-blas-dev |
    grep -q '^install ok installed$'
ldconfig -p | grep -q libamdhip64
ldconfig -p | grep -q libhsa-runtime64
# BLAS is asserted by its headers, not by a library: amdrocm-blas-dev is
# headers-only in the therock stream and does not depend on the runtime
# amdrocm-blas, so there is no librocblas.so here.
HIPBLAS_H=""
for h in /opt/rocm/include/hipblas/hipblas.h \
         /opt/rocm/*/include/hipblas/hipblas.h; do
    [ -e "${h}" ] && HIPBLAS_H="${h}"
done
test -n "${HIPBLAS_H}"

# The module modprobe would pick must be the DKMS one, built for the kernel
# this guest actually booted, and it must be a driver with GC 12.1.0 -- which
# is asserted by the firmware it names, since a driver without gfx1250 support
# does not reference gc_12_1_0 at all.
AMDGPU_KO=$(modinfo -n amdgpu)
test -n "${AMDGPU_KO}"
echo "amdgpu.ko: ${AMDGPU_KO}"
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'gc_12_1_0'
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'sdma_7_1_0'
# emu_mode is what rocjitsu passes; a driver without it is the wrong driver.
modinfo -F parm "${AMDGPU_KO}" | grep -q '^emu_mode:'
dkms status amdgpu -k "$(uname -r)" | grep -q 'installed'
case "${AMDGPU_KO}" in
    */updates/dkms/*) ;;
    *)
        echo "error: modprobe would load ${AMDGPU_KO}, not the DKMS module" >&2
        exit 1
        ;;
esac
modinfo -F version "${AMDGPU_KO}"

# Every patch, asserted by a marker unique to its own hunk, in the *source*
# tree -- which is what survives a later "dkms autoinstall" on a new kernel and
# what a consumer rebuilding the module would get.  A driver bump that quietly
# drops one has to fail here and not in the emulated device's early init.
AMDGPU_SRC=$(ls -d /usr/src/amdgpu-* | tail -1)
# KFD atomics: the emulated device cannot advertise PCIe atomics through the
# vfio-user PCI capability, and KFD refuses a device without them.
grep -q 'amdgpu_emu_mode == 1' "${AMDGPU_SRC}/amd/amdkfd/kfd_device.c"
# 0001, the unreviewed ptrace gate.  See
# assets/ernic-rocjitsu/patches/amdgpu/README.md.
grep -q 'KERNEL_VERSION(7, 2, 0)' \
    "${AMDGPU_SRC}/amd/amdkfd/kfd_process_queue_manager.c"
# 0002, the panel_type probes.
grep -q 'AC_AMDGPU_DRM_DISPLAY_INFO_PANEL_TYPE' \
    "${AMDGPU_SRC}/amd/dkms/m4/drm-display-info.m4"
grep -q 'AC_AMDGPU_DRM_MODE_PANEL_TYPE_LCD' \
    "${AMDGPU_SRC}/amd/dkms/m4/drm-display-info.m4"
grep -q 'HAVE_DRM_DISPLAY_INFO_PANEL_TYPE' \
    "${AMDGPU_SRC}/amd/display/amdgpu_dm/amdgpu_dm_connector.c"
# 0003, the RAS vbios guard: rocjitsu serves no option ROM, so atom_context is
# NULL and the unguarded query oopses in amdgpu_atom_parse_data_header.
grep -q 'adev->mode_info.atom_context' "${AMDGPU_SRC}/amd/amdgpu/amdgpu_ras.c"

# amdgpu must not autoload -- it is modprobed by hand with the emulation
# parameters once the vfio-user server is serving.  Belt (modprobe.d) and
# braces (kernel cmdline, which also covers a load from the initramfs).
grep -qx 'blacklist amdgpu' /etc/modprobe.d/amdgpu-blacklist.conf
grep -q 'modprobe.blacklist=amdgpu' /proc/cmdline
! lsmod | grep -q '^amdgpu '

# The probe helper is offered, not run: the blacklist above still stands.  The
# same file the rocjitsu flavour installs, from assets/shared -- asserted in
# both so the two cannot drift.
test -x /usr/local/bin/amdgpu-probe
bash -n /usr/local/bin/amdgpu-probe
grep -q 'ip_block_mask=0x7f' /usr/local/bin/amdgpu-probe
grep -q 'vramlimit=1024' /usr/local/bin/amdgpu-probe

# Firmware.  Unlike the rocjitsu flavour, this guest carries the generated gap
# set as well as the packaged blobs, so there is nothing left that amdgpu opens
# and the guest lacks -- and that is asserted as an empty list rather than an
# expected-absent one.  Which names the driver actually opens is asked of the
# module rather than listed here: modinfo reports its MODULE_FIRMWARE
# declarations, so a driver bump that adds a name shows up as a missing file
# instead of going unnoticed.
#
# ip_discovery.bin is not in this set and is not a firmware name the module
# declares: amdgpu.discovery=2 reads it by path, and it comes from the
# consumer's own rocjitsu pin.
MISSING=$(modinfo -F firmware "${AMDGPU_KO}" |
    grep -E 'gc_12_1_0|sdma_7_1_0' |
    while read -r fw; do
        [ -n "${fw}" ] || continue
        for dir in /lib/firmware/updates /lib/firmware; do
            if [ -e "${dir}/${fw}" ] || [ -e "${dir}/${fw}.xz" ]; then
                continue 2
            fi
        done
        echo "${fw}"
    done)
if [ -n "${MISSING}" ]; then
    echo "Error: amdgpu opens firmware this image does not carry:" >&2
    echo "${MISSING}" | sed 's/^/  /' >&2
    exit 1
fi
# And the three the generator produced are the three it said it produced.
test -s /lib/firmware/updates/amdgpu/rocjitsu-gap-manifest.json
for fw in $(python3 -c \
    'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["files"]))' \
    /lib/firmware/updates/amdgpu/rocjitsu-gap-manifest.json); do
    test -s "/lib/firmware/updates/amdgpu/${fw}"
done
test ! -e /lib/firmware/updates/amdgpu/ip_discovery.bin

# --- the guest itself ----------------------------------------------------

# /dev/kfd and /dev/dri/render* are root:render 0660, and a login user in
# neither group gets a HIP runtime that enumerates no agent and a hipMalloc
# returning hipErrorNoDevice with a healthy KFD node three lines up the log.
id -nG | tr ' ' '\n' | grep -qx render
id -nG | tr ' ' '\n' | grep -qx video

# The flavour's own record, for a consumer reading it from inside the guest,
# and the same facts as prose where someone who has just ssh'd in will see them.
test -s /etc/ernic-rocjitsu-guest.json
test -s "${HOME}/WELCOME.md"

# Headroom for a kernel tree, rdma-core, the ionic-ernic DKMS build and a
# consumer's own build tree.
test "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 20

# The shipped netplan has to match the NIC by name, not by the MAC cloud-init
# happened to see at creation.  Three different MACs boot this one image:
# gen-vm's first boot derives 52:54:00:00:08:ae from --ssh-port 2222, this
# probe boot gets QEMU's default 52:54:00:12:34:56 because probe-guest.sh
# passes no mac=, and a consumer's run-vm is back to 08:ae.  So any macaddress:
# pin is wrong for at least one of them, and it surfaces as an addressless NIC
# and an SSH timeout in a consumer's job rather than as anything anyone can act
# on.  qemu-tool writes the name match late in first boot via cloud-init
# write_files defer; this asserts it landed.
sudo -n grep -q 'name: *"\?en\*' /etc/netplan/50-cloud-init.yaml
test -z "$(sudo -n grep -l macaddress /etc/netplan/*.yaml || true)"
