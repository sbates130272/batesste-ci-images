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

# ROCM_PATH and PATH, from /etc/profile.d/rocm.sh. ld.so.conf above covers the
# linker; this covers the shell, which is a different failure and the one
# consumers actually hit -- the therock component directory is versioned, so a
# login session finds no ROCm tooling and no ROCM_PATH without being told.
#
# Asserted through an actual login shell rather than by reading the file: that
# the file exists proves nothing about whether anything sources it.
test -s /etc/profile.d/rocm.sh
LOGIN_ROCM_PATH=$(bash -lc 'echo "${ROCM_PATH}"')
test -n "${LOGIN_ROCM_PATH}"
test -d "${LOGIN_ROCM_PATH}"
# By the PATH entry itself, not by resolving a tool through it: rocminfo and
# friends are not in this guest's minimal set, for the reasons above.
bash -lc 'case ":${PATH}:" in *":${ROCM_PATH}/bin:"*) ;; *) exit 1 ;; esac'
echo "note: login-shell ROCM_PATH=${LOGIN_ROCM_PATH}"

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

# The RAS vbios guard: rocjitsu serves no option ROM, so atom_context is NULL
# and the unguarded query oopses in amdgpu_atom_parse_data_header on probe.
grep -q 'adev->mode_info.atom_context' \
    /usr/src/amdgpu-*/amd/amdgpu/amdgpu_ras.c

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

# The probe helper is offered, not run: the blacklist above still stands.  It
# is asserted because the perf lane invokes it by name, and because a guest
# without it sends every consumer back to reconstructing the parameters.
test -x /usr/local/bin/amdgpu-probe
bash -n /usr/local/bin/amdgpu-probe
grep -q 'ip_block_mask=0x7f' /usr/local/bin/amdgpu-probe
grep -q 'vramlimit=1024' /usr/local/bin/amdgpu-probe

# /dev/kfd and /dev/dri/render* are root:render 0660, and a login user in
# neither group gets a HIP runtime that enumerates no agent and a hipMalloc
# returning hipErrorNoDevice with a healthy KFD node three lines up the log.
# Neither device node exists in this boot, so the group membership is what can
# be asserted -- and it is the half that is the image's to get right.
id -nG | tr ' ' '\n' | grep -qx render
id -nG | tr ' ' '\n' | grep -qx video

# The flavour's own record, for a consumer reading it from inside the guest,
# and the same facts as prose where someone who has just ssh'd in will see them.
test -s /etc/rocjitsu-guest.json
test -s "${HOME}/WELCOME.md"

# fio, built from source with the libhipfile ioengine.  Asserted by the engine
# and not by the binary: a distro fio would satisfy "command -v fio" and has no
# libhipfile at all, so the version that matters is the one --enghelp reports.
# The engine cannot be exercised here -- it needs a GPU, and this boot has none
# -- but an fio that cannot name it is an fio that will fail at the point of
# measurement instead, in a guest a consumer has already spent an hour booting.
command -v fio
fio --enghelp | grep -qE '^[[:space:]]*libhipfile$'
fio --enghelp | grep -qE '^[[:space:]]*libaio$'
test -s /usr/local/share/fio-commit.txt
echo "fio: $(fio --version) from $(cat /usr/local/share/fio-commit.txt)"
# /usr/local, so it is the source build on PATH rather than a distro copy that
# something pulled in as a dependency later.
test "$(command -v fio)" = /usr/local/bin/fio

# ibverbs userspace.  No device and no RDMA driver here by design, so this
# asserts only that the tooling resolves -- "no devices" is the expected and
# correct answer, and is a different failure from "command not found".
command -v ibv_devinfo
ldconfig -p | grep -q libibverbs
ibv_devinfo -l || true

# gfx1250 firmware is not this image's to carry, so this cannot assert files.
#
# It used to: amdgpu-dkms depends on amdgpu-dkms-firmware, and the 31.60 tree
# shipped real gc_12_1_0 and sdma_7_1_0 blobs, so every name the module opened
# bar three had to be on disk. 31.60 has been withdrawn from repo.radeon.com,
# and 31.50 -- the newest tree still serving this release -- packages none of
# them, so the whole set now comes from vfio_guest_firmware.py at the
# consumer's own rocjitsu pin (--set full --generation gfx1250). Asserting
# presence here would fail every build by design.
#
# What is still worth asserting is the half this image does own: that the
# driver it built has gfx1250 support at all. A driver without it never names
# gc_12_1_0 or sdma_7_1_0 in its MODULE_FIRMWARE declarations, and a guest
# built that way rejects the emulated device long before firmware is opened.
# Same assertion checks/ernic-rocjitsu.sh makes, for the same reason.
#
# Scoped to gc_12_1_0 and sdma_7_1_0 only. rocm-xio's own assert also greps
# "mes", which matches the gc_11 and gc_12_0 blobs that every release ships --
# so that pattern can pass on a guest carrying no gfx1250 support at all.
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'gc_12_1_0'
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'sdma_7_1_0'
echo "note: amdgpu declares gfx1250 firmware; the set itself is the consumer's"
echo "      to install -- see /etc/rocjitsu-guest.json"
modinfo -F firmware "${AMDGPU_KO}" | grep -E 'gc_12_1_0|sdma_7_1_0' |
    sed 's/^/  /'

# Headroom for a rocm-xio build tree and a module build.
test "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 20

# The shipped netplan has to match the NIC by name, not by the MAC cloud-init
# happened to see at creation. Three different MACs boot this one image:
# gen-vm's first boot derives 52:54:00:00:08:ae from --ssh-port 2222, this
# probe boot gets QEMU's default 52:54:00:12:34:56 because probe-guest.sh
# passes no mac=, and the perf lane's run-vm is back to 08:ae. So any
# macaddress: pin is wrong for at least one of them, and it surfaces as an
# addressless NIC and an SSH timeout in a consumer's job rather than as
# anything anyone can act on. qemu-tool writes the name match late in first
# boot via cloud-init write_files defer; this asserts it landed.
sudo -n grep -q 'name: *"\?en\*' /etc/netplan/50-cloud-init.yaml
test -z "$(sudo -n grep -l macaddress /etc/netplan/*.yaml || true)"
