# shellcheck shell=bash
#
# Assertions run inside the "rocjitsu" guest during the build's probe boot.
# Appended to a "set -eu" bash script, so any failing command fails the build.
#
# This boot has no GPU -- the device only exists when a consumer runs rocjitsu
# and modprobes amdgpu against the vfio-user socket -- so nothing here can
# assert the device comes up.  What it can assert is that everything the
# consumer would otherwise have had to install and patch at runtime is present
# and in the state it promised.

# The published guest must boot a 7.0 or newer kernel: 7.0 is the first one
# whose in-tree amdgpu carries GC 12.1.0, and it is what the 26.04 amdgpu-dkms
# is built against here. On resolute that is the release's own HWE kernel; on
# noble it is the HWE metapackage installed during provisioning, which the
# provisioning boot itself was not running. Compare the whole version tuple,
# not major-and-minor separately.
test "$(printf '7.0\n%s\n' "$(uname -r)" | sort -V | head -1)" = "7.0"
. /etc/os-release

# The toolchain and headers, so an out-of-tree module can be built here.
command -v gcc make cmake ninja dkms git
test -d /lib/modules/"$(uname -r)"/build

# ROCm userspace: the minimal set rocm-xio links against, from the therock
# stream rather than the universe copies pinned out in provisioning.
dpkg-query -W -f='${Status}' amdrocm-runtime-dev |
    grep -q '^install ok installed$'
dpkg-query -W -f='${Status}' amdrocm-blas-dev |
    grep -q '^install ok installed$'
#
# rocminfo is deliberately not asserted: it is not in the requested minimal
# set, the therock runtime package does not carry it, and the distro copy is
# pinned to never-install. Assert the libraries instead -- they are what
# rocm-xio links against, and they are what the ld.so.conf written during
# provisioning has to resolve.
ldconfig -p | grep -q libamdhip64
ldconfig -p | grep -q libhsa-runtime64
# BLAS is asserted by its headers, not by a library: amdrocm-blas-dev is
# headers-only in the therock stream and does not depend on the runtime
# amdrocm-blas, so there is no librocblas.so here. That is the minimal set
# exactly as requested -- a consumer needing the shared library at run time has
# to ask for amdrocm-blas as well.
HIPBLAS_H=""
for h in /opt/rocm/include/hipblas/hipblas.h \
         /opt/rocm/*/include/hipblas/hipblas.h; do
    [ -e "${h}" ] && HIPBLAS_H="${h}"
done
test -n "${HIPBLAS_H}"

# Whichever module modprobe would pick -- the DKMS one on resolute, the in-tree
# one on noble -- it must be a driver with GC 12.1.0. Assert it by the firmware
# it names: a driver without gfx1250 support does not reference gc_12_1_0 at
# all.
AMDGPU_KO=$(modinfo -n amdgpu)
test -n "${AMDGPU_KO}"
echo "amdgpu.ko: ${AMDGPU_KO}"
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'gc_12_1_0'
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'sdma_7_1_0'
# emu_mode is what rocjitsu passes; a driver without it is the wrong driver.
modinfo -F parm "${AMDGPU_KO}" | grep -q '^emu_mode:'

# amdgpu-dkms, carrying the KFD atomics patch in its source tree.
dkms status amdgpu | grep -q '^amdgpu'
grep -q 'amdgpu_emu_mode == 1' \
    /usr/src/amdgpu-*/amd/amdkfd/kfd_device.c

# On 26.04 the DKMS module is the driver that loads, so it has to exist for the
# kernel this guest actually booted -- not merely for some kernel. A module
# built for the provisioning kernel and nothing else is exactly the failure this
# flavour moved off noble to avoid, and dkms status without -k hides it.
if [ "${VERSION_ID}" = "26.04" ]; then
    dkms status amdgpu -k "$(uname -r)" | grep -q 'installed'
    case "${AMDGPU_KO}" in
        */updates/dkms/*) ;;
        *)
            echo "error: modprobe would load ${AMDGPU_KO}, not the DKMS module" >&2
            exit 1
            ;;
    esac
    modinfo -F version "${AMDGPU_KO}"
else
    # noble: the DKMS module is for the 6.8 provisioning kernel and cannot load
    # at all, so it is only a patched source tree a consumer can build from.
    # See consumers/rocm-xio-rocjitsu.md.
    echo "note: noble build -- DKMS module is not the runtime driver"
fi

# amdgpu must not autoload -- it is modprobed by hand with the emulation
# parameters once the vfio-user server is serving. Belt (modprobe.d) and
# braces (kernel cmdline, which also covers a load from the initramfs).
grep -qx 'blacklist amdgpu' /etc/modprobe.d/amdgpu-blacklist.conf
grep -q 'modprobe.blacklist=amdgpu' /proc/cmdline
! lsmod | grep -q '^amdgpu '

# The flavour's own record, for a consumer reading it from inside the guest.
test -s /etc/rocjitsu-guest.json

# gfx1250 firmware is NOT baked in: no linux-firmware or amdgpu-dkms-firmware
# release carries gc_12_1_0 or sdma_7_1_0 blobs (31.50's has 683 files and none
# of them), so there is nothing to install from a package. Report the inventory
# so the build log says plainly what is missing, and leave the check non-fatal
# -- supplying it, from ubuntu-rocm-rocjitsu's vfio_guest_firmware.py at the
# consumer's own rocjitsu pin, is the consumer's step.
#
# Scoped to gc_12_1_0 and sdma_7_1_0 only. rocm-xio's own assert also greps
# "mes", which matches the gc_11 and gc_12_0 blobs that every release ships --
# so that pattern can pass on a guest carrying no gfx1250 firmware at all.
MISSING=$(modinfo -F firmware "${AMDGPU_KO}" |
    grep -E 'gc_12_1_0|sdma_7_1_0' |
    while read -r fw; do
        [ -n "${fw}" ] || continue
        [ -e "/lib/firmware/${fw}" ] || [ -e "/lib/firmware/${fw}.xz" ] ||
            echo "  ${fw}"
    done)
if [ -n "${MISSING}" ]; then
    echo "note: firmware blobs amdgpu requests that this image does not carry:"
    echo "${MISSING}"
else
    echo "note: every gfx1250 firmware blob this amdgpu.ko names is present"
fi

# Headroom for a rocm-xio build tree and a module build.
test "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 20
