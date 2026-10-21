# shellcheck shell=bash
#
# Assertions run inside the "ernic-rocjitsu-slim" guest during the build's
# probe boot.  Appended to a "set -eu" bash script, so any failing command
# fails the build.
#
# Derived from checks/ernic-rocjitsu.sh, and the differences are the point of
# the flavour.  This guest is that one, built by the same provision script and
# then trimmed by trim/slim.sh, so everything about the *devices* is asserted
# identically -- the kernel floor, the patched module modprobe would pick, the
# blacklist, the firmware, the ionic provider.  What is dropped is everything
# that asserted a build capability this flavour deliberately gave up.
#
# The negative assertions at the end are not decoration.  A slim flavour whose
# trim quietly stops removing something is a 9 GB image wearing a 2 GB name,
# and nothing else in the build would notice: the package-presence assertion
# in build-vm.sh is skipped for a trimmed flavour precisely because it cannot
# describe this guest.  These are what does.
#
# Not asserted here, unlike the fat flavour: the amdgpu patch markers in
# /usr/src/amdgpu-*.  That tree is gone by design.  The patched build is
# asserted by behaviour instead -- it resolves under updates/dkms, it declares
# the gc_12_1_0 firmware a driver without gfx1250 support does not reference,
# and it carries emu_mode -- and the fat flavour, built from the same script,
# still asserts every marker on the sources themselves.

# The floor the whole flavour turns on.  ionic_rdma calls ib_umem_get_va, which
# exists in 7.2.4 and does not in 7.0 or 7.1.13.  Asserted by version only: the
# headers that carried the symbol are part of what the trim removed, and the
# module that needed them is already built.
test "$(printf '7.2\n%s\n' "$(uname -r)" | sort -V | head -1)" = "7.2"
. /etc/os-release

# --- the ionic half ------------------------------------------------------

# The RDMA stack ships with the mainline kernel rather than needing a build,
# which is why this half survives the trim intact.
command -v ibv_devinfo
modinfo ionic_rdma > /dev/null
ldconfig -p | grep -q libibverbs

# The SRQ stack, and this is the flavour where it matters most: there is no
# compiler here, so a consumer who finds max_srq = 0 cannot fix it in the
# guest.  It has to be right in the image or not at all.
#
# Asserted on the artefacts rather than on the symbol table, unlike the fat
# flavour: binutils went with the toolchain, so there is no nm to run.  The
# symbol check belongs to the build -- it ran before the trim, while a
# compiler still existed -- and this asserts what survived it.
test -s /etc/ionic-srq.json
python3 -c 'import json; json.load(open("/etc/ionic-srq.json"))'
IONIC_KO=$(modinfo -n ionic_rdma)
case "${IONIC_KO}" in
    */updates/dkms/*) ;;
    *)
        echo "ERROR: modprobe would load ${IONIC_KO}, not the SRQ-capable" \
             "DKMS module; /etc/ionic-srq.json says this guest has one" >&2
        exit 1
        ;;
esac
ls /usr/local/lib/libibverbs/libionic-rdmav*.so
ldd "$(command -v ibv_devinfo)" | grep -q '/usr/local/lib/libibverbs'
# Resolution, not presence -- the same reason the ROCm assertions below use
# ldd.  An autoremove that took a dependency out from under the /usr/local
# libibverbs leaves a guest where the file is on disk and every verbs tool is
# broken.
if ldd "$(command -v ibv_devinfo)" 2>&1 | grep -q 'not found'; then
    echo "ERROR: ibv_devinfo has unresolved dependencies:" >&2
    ldd "$(command -v ibv_devinfo)" 2>&1 | grep 'not found' >&2
    exit 1
fi
python3 -c 'import json; d = json.load(open("/etc/slim-trim.json")); assert d["ionic_srq_stack_kept"] is True, d'

# providers/ionic, from the archive's ibverbs-providers.  The provider carries
# the ABI suffix rather than a bare name -- libionic-rdmav59.so at 61.0 -- so
# match on the prefix.
ls /usr/lib/*/libibverbs/libionic*.so
dpkg -S /usr/lib/*/libibverbs/libionic*.so > /dev/null

# The stamp ernic_guest_setup reads.  No version literal: compare it against
# dpkg rather than against a copy of the pin.
STAMP=$(cat /usr/local/share/rocm-ernic/provider.stamp)
test "${STAMP#*:}" = none
INSTALLED=$(dpkg-query -W -f='${Version}' rdma-core)
test "${STAMP%%:*}" = "${INSTALLED%%-*}"

# Traffic generators.  Kept through the trim on purpose: they are runtime
# tools, and a guest with no compiler cannot install them later.
command -v ib_send_bw ib_write_bw ib_read_bw ib_send_lat

# Locked memory, for the fat flavour's reason -- RDMA pins memory and this
# release defaults to 8192 KB, which surfaces as every ibv_reg_mr() failing
# with "Cannot allocate memory" a long way from anything saying memlock.
# This boot is a fresh login on a booted guest, which is the only place the
# PAM limit and the systemd drop-in can both be observed.
test "$(ulimit -l)" = unlimited
grep -q 'DefaultLimitMEMLOCK=infinity' /etc/systemd/system.conf.d/*.conf
systemctl show -p DefaultLimitMEMLOCK | grep -q 'infinity$'

# --- the rocjitsu half ---------------------------------------------------

# ROCm userspace.  Asserted through the dynamic loader rather than through
# package state: the trim purges the -dev packages and deletes dpkg-owned
# subtrees under ${ROCM_PATH}, so what matters is that the runtime libraries
# still resolve, not what dpkg believes about what shipped them.
#
# And resolve means resolve.  "ldconfig -p | grep" is a cache lookup: it passes
# for a library whose NEEDED entries were deleted out from under it, which is
# exactly the guest a subtractive build can produce -- libamdhip64 needs
# libamd_comgr, and comgr reaches libLLVM and libclang-cpp through an RPATH
# into lib/llvm, which the trim prunes.  ldd is transitive and would have
# caught it.
HIP_SO=$(ldconfig -p | awk '/libamdhip64\.so\.[0-9]/ {print $NF; exit}')
HSA_SO=$(ldconfig -p | awk '/libhsa-runtime64\.so\.[0-9]/ {print $NF; exit}')
test -n "${HIP_SO}"
test -n "${HSA_SO}"
for so in "${HIP_SO}" "${HSA_SO}"; do
    if ldd "${so}" 2>&1 | grep -q 'not found'; then
        echo "ERROR: ${so} has unresolved dependencies:" >&2
        ldd "${so}" 2>&1 | grep 'not found' >&2
        exit 1
    fi
done

# ROCM_PATH and PATH from /etc/profile.d/rocm.sh, asserted through an actual
# login shell: that the file exists proves nothing about whether anything
# sources it.
test -s /etc/profile.d/rocm.sh
LOGIN_ROCM_PATH=$(bash -lc 'echo "${ROCM_PATH}"')
test -n "${LOGIN_ROCM_PATH}"
test -d "${LOGIN_ROCM_PATH}"
bash -lc 'case ":${PATH}:" in *":${ROCM_PATH}/bin:"*) ;; *) exit 1 ;; esac'
echo "note: login-shell ROCM_PATH=${LOGIN_ROCM_PATH}"
# The device bitcode the runtime loads at dispatch.  Deleting it along with
# LLVM would leave a guest that links and then fails to launch a kernel, which
# is a far more expensive failure than a missing compiler.
#
# Asserted through the files and not only the directory: ${ROCM_PATH}/amdgcn is
# a symlink into lib/llvm/amdgcn, so "test -d" passes on a dangling link only
# by dereference, and the trim prunes exactly that tree.
test -d "${LOGIN_ROCM_PATH}/amdgcn/bitcode"
test -s "${LOGIN_ROCM_PATH}/amdgcn/bitcode/hip.bc"
test -s "${LOGIN_ROCM_PATH}/amdgcn/bitcode/ockl.bc"
test -s "${LOGIN_ROCM_PATH}/lib/llvm/amdgcn/bitcode/hip.bc"

# The module modprobe would pick must still be the patched DKMS build, for the
# kernel this guest booted -- the trim removes the package that owned it and
# puts the module back, so this is the assertion that step is worth.
AMDGPU_KO=$(modinfo -n amdgpu)
test -n "${AMDGPU_KO}"
echo "amdgpu.ko: ${AMDGPU_KO}"
case "${AMDGPU_KO}" in
    */updates/dkms/*) ;;
    *)
        echo "error: modprobe would load ${AMDGPU_KO}, not the DKMS module" >&2
        exit 1
        ;;
esac
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'gc_12_1_0'
modinfo -F firmware "${AMDGPU_KO}" | grep -q 'sdma_7_1_0'
modinfo -F parm "${AMDGPU_KO}" | grep -q '^emu_mode:'
modinfo -F version "${AMDGPU_KO}"
# And depmod still resolves it: the trim purges the package that owned this
# module and puts the file back by hand, which rewrites modules.dep twice.  A
# dry-run modprobe is what proves the module is reachable through that file
# rather than merely present on disk.  It inserts nothing, so the blacklist
# below still stands -- and it does not prove the module loads, which no boot
# without the emulated device could prove anyway.
sudo -n modprobe -n amdgpu

# amdgpu must not autoload -- it is modprobed by hand with the emulation
# parameters once the vfio-user server is serving.
grep -qx 'blacklist amdgpu' /etc/modprobe.d/amdgpu-blacklist.conf
grep -q 'modprobe.blacklist=amdgpu' /proc/cmdline
if lsmod | grep -q '^amdgpu '; then
    echo "ERROR: amdgpu is loaded; it must be modprobed by hand after the" >&2
    echo "       vfio-user server is serving, not autoloaded at boot" >&2
    exit 1
fi

# And absent from the initramfs, not merely blacklisted inside it.  The trim
# rebuilds every initramfs, so this also proves the exclude hook survived that
# rebuild.
#
# if/exit, not `! lsinitramfs ... | grep -q ...`: bash never applies set -e to
# a command whose status is inverted with `!`.
for img in /boot/initrd.img-*; do
    [ -e "${img}" ] || continue
    if lsinitramfs "${img}" | grep -qE '(^|/)amdgpu\.ko(\.[a-z]+)?$'; then
        echo "ERROR: amdgpu.ko is present in ${img}" >&2
        exit 1
    fi
done

# And the initramfs is still a general one.  The negative above passes just as
# happily on an initrd that carries nothing at all, which is the shape
# MODULES=dep produces: it keeps only what the *build* machine needed, so the
# build goes green and a consumer whose root disk is not this build's topology
# drops to an initramfs shell.
#
# Counted rather than checked by name, and that is not laziness.  The obvious
# assertion -- virtio_pci, virtio_blk, ext4 are present -- can never pass on
# this kernel: mainline 7.2.4 builds CONFIG_VIRTIO_PCI, CONFIG_VIRTIO_BLK,
# CONFIG_SCSI_VIRTIO and CONFIG_EXT4_FS as "y", so no such module exists to
# find and their absence says nothing.  What a pruned initrd really loses here
# is the drivers that *are* modules -- nvme and ahci among them -- and the
# honest way to see that is the size of the module set.  A MODULES=dep initrd
# on this guest carries a handful; a general one carries hundreds.
MODCOUNT=$(lsinitramfs "/boot/initrd.img-$(uname -r)" |
    grep -cE '\.ko(\.[a-z]+)?$')
echo "note: initramfs carries ${MODCOUNT} modules"
if [ "${MODCOUNT}" -lt 100 ]; then
    echo "ERROR: the initramfs carries only ${MODCOUNT} modules; something" >&2
    echo "       has pruned it to this build's own hardware, which strands" >&2
    echo "       any consumer whose root disk is NVMe, AHCI or virtio-scsi" >&2
    exit 1
fi
# The root path itself, allowing for either shape: a module in the initrd, or
# built into the kernel, which is what this one does.
for m in VIRTIO_PCI VIRTIO_BLK EXT4_FS; do
    grep -q "^CONFIG_${m}=[ym]$" "/boot/config-$(uname -r)"
done

# The probe helper is offered, not run: the blacklist above still stands.
test -x /usr/local/bin/amdgpu-probe
bash -n /usr/local/bin/amdgpu-probe
grep -q 'ip_block_mask=0x7f' /usr/local/bin/amdgpu-probe
grep -q 'vramlimit=1024' /usr/local/bin/amdgpu-probe

# Firmware.  Unchanged from the fat flavour: the trim purges linux-firmware,
# which is a different package, and amdgpu-dkms-firmware is marked manual
# before the amdgpu-dkms purge so autoremove cannot take it.  Asserted as an
# empty list of names the module opens and the guest lacks.
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
test -s /lib/firmware/updates/amdgpu/rocjitsu-gap-manifest.json
for fw in $(python3 -c \
    'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["files"]))' \
    /lib/firmware/updates/amdgpu/rocjitsu-gap-manifest.json); do
    test -s "/lib/firmware/updates/amdgpu/${fw}"
done
test ! -e /lib/firmware/updates/amdgpu/ip_discovery.bin

# The staging directory for the one firmware file the consumer supplies.  See
# the fat flavour's note: the directory has to exist for the documented copy
# to land, and must not already hold a blob from somebody else's rocjitsu pin.
test -d /lib/firmware/amdgpu
test ! -e /lib/firmware/amdgpu/ip_discovery.bin

# --- what the trim removed -----------------------------------------------
#
# The flavour's whole reason for existing, asserted as negatives.  Without
# these, a trim step that silently stopped working ships a fat guest under a
# slim name and every check above still passes.

# No toolchain.  Checked on both PATHs: this script runs over
# `ssh ... 'bash -s'`, which is neither a login nor an interactive shell, so
# /etc/profile.d/rocm.sh is never sourced and a bare "command -v hipcc" could
# not fire no matter what ${ROCM_PATH}/bin held.  The login PATH is the one a
# consumer gets.
for tool in gcc cc g++ make cmake ninja dkms git hipcc hipconfig \
            amdclang amdclang++; do
    if command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: ${tool} is present; trim/slim.sh should have removed it" >&2
        exit 1
    fi
    if bash -lc "command -v '${tool}'" > /dev/null 2>&1; then
        echo "ERROR: ${tool} is on the login PATH; trim/slim.sh should have" \
             "removed it" >&2
        exit 1
    fi
done

# No DKMS source tree, no kernel headers, no second kernel.
test ! -e /var/lib/dkms
test -z "$(ls -d /usr/src/amdgpu-* 2>/dev/null || true)"
test ! -e "/lib/modules/$(uname -r)/build"
test "$(ls -1 /boot/vmlinuz-* | wc -l)" -eq 1
test -e "/boot/vmlinuz-$(uname -r)"

# Packages whose absence is the bulk of the saving.  dpkg-query exits non-zero
# for a package it has never heard of, so test the status rather than the exit
# code: a purged package is still known to dpkg and reports "deinstall".
for pkg in linux-firmware snapd build-essential; do
    if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null |
            grep -q '^install ok installed$'; then
        echo "ERROR: ${pkg} is installed; trim/slim.sh should have purged it" >&2
        exit 1
    fi
done

# cloud-init disabled, and the netplan it wrote still in place -- the second
# half matters more than the first, because that file is what gives this guest
# an address and purging cloud-init is how it would have been lost.
#
# The units are asserted and not just the flag file: cloud-init.service is an
# alias on this release and systemd will not mask an alias, so a mask that
# silently did nothing is the failure mode worth catching here.
test -e /etc/cloud/cloud-init.disabled
for u in cloud-init-local cloud-init-network cloud-config cloud-final; do
    state=$(systemctl is-enabled "${u}.service" 2>/dev/null || true)
    case "${state}" in
        masked|disabled|"") ;;
        *)
            echo "ERROR: ${u}.service is ${state}, not masked" >&2
            exit 1
            ;;
    esac
done

# ROCm's build half is gone but the runtime half is not.  lib/llvm survives as
# a pruned directory, by design: libamd_comgr resolves libLLVM and libclang-cpp
# out of it through an RPATH, and the device bitcode lives beside them.  What
# must be gone is everything a consumer could compile with.
test ! -e "${LOGIN_ROCM_PATH}/lib/llvm/bin"
test ! -e "${LOGIN_ROCM_PATH}/lib/llvm/include"
test ! -e "${LOGIN_ROCM_PATH}/lib/llvm/lib/clang"
test ! -e "${LOGIN_ROCM_PATH}/bin/hipcc"
test ! -e "${LOGIN_ROCM_PATH}/include"
test -d "${LOGIN_ROCM_PATH}/lib/llvm/amdgcn"
ls "${LOGIN_ROCM_PATH}"/lib/llvm/lib/libLLVM.so.* > /dev/null
ls "${LOGIN_ROCM_PATH}"/lib/llvm/lib/libclang-cpp.so.* > /dev/null
# The expensive half of the prune, asserted so it cannot silently stop working.
test -z "$(ls "${LOGIN_ROCM_PATH}"/lib/llvm/lib/libMLIR.so.* 2>/dev/null || true)"

# The ROCm -dev packages are gone as packages, not merely as files.
for pkg in "amdrocm-runtime-dev" "amdrocm-llvm-dev" "amdrocm-blas-dev"; do
    if dpkg-query -W -f='${Package} ${Status}\n' "${pkg}*" 2>/dev/null |
            grep -q ' install ok installed$'; then
        echo "ERROR: ${pkg}* is still installed; trim/slim.sh should have" \
             "purged it" >&2
        exit 1
    fi
done

# The grub snippet that makes the boot quick, and the pinned-kernel default it
# must not have disturbed.  build-vm's probe asserts the default resolves to
# the pinned kernel; this asserts the timeout reached the generated config,
# which is the half that is this trim's to get right.
#
# timeout_style is the variable that makes this assertion mean something:
# 50-cloudimg-settings.cfg already sets GRUB_TIMEOUT=0 on a cloud image, so
# "set timeout=0" alone passes on the fat flavour too.
test -s /etc/default/grub.d/99-slim-fastboot.cfg
grep -q '^GRUB_RECORDFAIL_TIMEOUT=0$' /etc/default/grub.d/99-slim-fastboot.cfg
sudo -n grep -q 'set timeout_style=hidden' /boot/grub/grub.cfg
sudo -n grep -q 'set timeout=0' /boot/grub/grub.cfg

# --- the guest itself ----------------------------------------------------

# /dev/kfd and /dev/dri/render* are root:render 0660, and a login user in
# neither group gets a HIP runtime that enumerates no agent.
id -nG | tr ' ' '\n' | grep -qx render
id -nG | tr ' ' '\n' | grep -qx video

# The flavour's own records: the provision script's, unchanged, and the trim's.
test -s /etc/ernic-rocjitsu-guest.json
test -s /etc/slim-trim.json
python3 -c 'import json; d = json.load(open("/etc/slim-trim.json")); assert d["in_guest_builds"] is False and d["kernels_installed"] == 1, d'
test -s "${HOME}/WELCOME.md"
grep -q 'This is the slim guest' "${HOME}/WELCOME.md"

# The size the flavour exists to deliver.  A ceiling rather than a target, and
# generous enough not to fail on an archive that grew a little -- but low
# enough that losing a whole trim section (the ROCm -dev packages are ~1.9 GB,
# the DKMS source ~2 GB, the toolchain and the LLVM prune ~0.7 GB between them)
# fails here instead of shipping.  Raising it is a decision, not a fix.
#
# MiB rather than GB, because "df -BG" rounds the block count *up*: 4097 MiB
# prints as "5G", so a "-ge 5" test is really a 4096 MiB cliff sitting a couple
# of hundred MB from the expected footprint -- a check that would have started
# failing on a guest nobody had changed.
USED_MIB=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
echo "note: root filesystem uses ${USED_MIB} MiB"
if [ "${USED_MIB}" -ge 5120 ]; then
    echo "ERROR: the slim guest uses ${USED_MIB} MiB (ceiling 5120); a trim" >&2
    echo "       step has stopped working, or the fat flavour grew." >&2
    echo "       See /etc/slim-trim.json for what the trim believes it did." >&2
    exit 1
fi

# Headroom for a consumer's own payload. Smaller than the fat flavour's 20 GB
# claim only because nothing here builds; the ceiling is the same 512 GB.
test "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 20

# The shipped netplan has to match the NIC by name, not by the MAC cloud-init
# happened to see at creation: three different MACs boot this one image, so any
# macaddress: pin is wrong for at least one of them. It surfaces as an
# addressless NIC and an SSH timeout in a consumer's job. This matters more
# here than in the fat flavour -- cloud-init is disabled, so nothing will
# regenerate the file if it is wrong.
sudo -n grep -q 'name: *"\?en\*' /etc/netplan/50-cloud-init.yaml
test -z "$(sudo -n grep -l macaddress /etc/netplan/*.yaml || true)"
