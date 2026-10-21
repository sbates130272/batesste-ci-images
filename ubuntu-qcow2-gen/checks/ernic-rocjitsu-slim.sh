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

# --- the rocjitsu half ---------------------------------------------------

# ROCm userspace.  Asserted through ldconfig rather than through package state:
# the trim deletes dpkg-owned subtrees under ${ROCM_PATH} (LLVM, headers,
# static libraries), so what matters is that the runtime libraries still
# resolve, not what dpkg believes about the package that shipped them.
ldconfig -p | grep -q libamdhip64
ldconfig -p | grep -q libhsa-runtime64

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
test -d "${LOGIN_ROCM_PATH}/amdgcn"

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
# rebuilds every initramfs (MODULES=dep, zstd), so this also proves the
# exclude hook survived that rebuild.
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

# --- what the trim removed -----------------------------------------------
#
# The flavour's whole reason for existing, asserted as negatives.  Without
# these, a trim step that silently stopped working ships a fat guest under a
# slim name and every check above still passes.

# No toolchain.  Named individually rather than as a loop over "command -v":
# which one came back is the first thing anyone debugging this wants to know.
for tool in gcc cc g++ make cmake ninja dkms git hipcc; do
    if command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: ${tool} is present; trim/slim.sh should have removed it" >&2
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
test -e /etc/cloud/cloud-init.disabled

# ROCm's build half is gone but the runtime half is not.  Asserted on the
# login shell's own ROCM_PATH, resolved above.
test ! -e "${LOGIN_ROCM_PATH}/lib/llvm"
test ! -e "${LOGIN_ROCM_PATH}/include"

# The grub snippet that makes the boot quick, and the pinned-kernel default it
# must not have disturbed.  build-vm's probe asserts the default resolves to
# the pinned kernel; this asserts the timeout reached the generated config,
# which is the half that is this trim's to get right.
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
# enough that losing a whole trim section (the toolchain is ~2 GB, the DKMS
# source ~2 GB, linux-firmware ~1.5 GB, ROCm's LLVM more than any of them)
# fails here instead of shipping.  Raising it is a decision, not a fix.
USED_GB=$(df --output=used -BG / | tail -1 | tr -dc 0-9)
echo "note: root filesystem uses ${USED_GB} GB"
if [ "${USED_GB}" -ge 5 ]; then
    echo "ERROR: the slim guest uses ${USED_GB} GB; a trim step has stopped" >&2
    echo "       working, or something large was added to the fat flavour." >&2
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
