# shellcheck shell=bash
#
# The "slim" trim, run by build-vm.sh in a PROBE_PERSIST boot after the
# flavour's provision script and before the verification boot.  It takes things
# back *out* of a finished guest: this is the same image the fat flavour
# produces -- same kernel, same patched amdgpu, same ionic half, same firmware
# -- with everything a runtime consumer cannot use removed.
#
# "Runtime consumer" is the contract, and it is a real loss: the guest that
# comes out of this cannot compile anything.  No gcc, no headers, no DKMS
# source.  A lane that builds ionic-ernic or hipObject inside the guest wants
# the fat flavour; this one is for booting a prebuilt binary against the two
# emulated devices, fast.
#
# Appended to a preamble that sets "set -eu" plus FLAVOUR, RELEASE, USERNAME,
# ROCM_PATH, ROCM_VERSION and KERNEL_REF, so any failing command fails the
# image build.  Runs as the guest user; root comes from sudo.
#
# Order matters.  Each section assumes the ones above it have run -- above all,
# the amdgpu module has to be rescued before anything purges the package that
# owns it.

echo "=== slim trim ==="
KVER=$(uname -r)
echo "kernel: ${KVER}  rocm: ${ROCM_PATH}"
USED_BEFORE=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
echo "root filesystem used before: ${USED_BEFORE} MiB"

export DEBIAN_FRONTEND=noninteractive
APT="sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120"

# Purge the names in "$@" that are actually installed, and say nothing about
# the ones that are not.
#
# apt-get purge fails the whole transaction on a name it has never heard of,
# and these lists necessarily name packages that may or may not be here -- a
# metapackage the release renamed, a daemon the cloud image dropped.  The
# obvious fix is "|| true", and it is the wrong one: it also swallows a purge
# that failed for a real reason, in a script whose entire job is removing
# things.  Filtering first means every purge that runs is one that must work.
purge_installed() {
    _p=""
    for _name in "$@"; do
        if dpkg-query -W -f='${Status}' "${_name}" 2>/dev/null |
                grep -q '^install ok installed$'; then
            _p="${_p} ${_name}"
        fi
    done
    if [ -n "${_p}" ]; then
        echo "purging:${_p}"
        # shellcheck disable=SC2086
        ${APT} purge -y ${_p}
    fi
}

# --- 1. amdgpu: keep the module, drop the source -------------------------
#
# /usr/src/amdgpu-* is ~2 GB and exists so a later "dkms autoinstall" can
# rebuild the patched driver for a new kernel.  This guest installs no kernels,
# so it buys nothing here -- but removing it means removing amdgpu-dkms, and
# that package's postrm runs "dkms remove", which deletes the module the fat
# build spent twenty minutes producing.
#
# So the module is saved first and reinstated afterwards, rather than hoping
# the postrm leaves it alone.  Everything below asserts itself: this is the one
# irreversible step in the trim, and a guest that comes out of it without a
# loadable patched amdgpu is worth no bytes at all.
AMDGPU_KO=$(modinfo -n amdgpu)
case "${AMDGPU_KO}" in
    */updates/dkms/*) ;;
    *)
        echo "Error: modprobe resolves amdgpu to ${AMDGPU_KO}, not the DKMS" \
             "module; the fat build should have failed before this ran" >&2
        exit 1
        ;;
esac
# Recorded before the purge so the restored module can be checked against it.
AMDGPU_FW_NAMES=$(modinfo -F firmware "${AMDGPU_KO}" | sort | tr '\n' ' ')
AMDGPU_MODVER=$(modinfo -F version "${AMDGPU_KO}")
AMDGPU_BASENAME=$(basename "${AMDGPU_KO}")
sudo install -d -m 0755 /var/tmp/slim-save
sudo cp -a "${AMDGPU_KO}" "/var/tmp/slim-save/${AMDGPU_BASENAME}"
echo "saved ${AMDGPU_KO} (version ${AMDGPU_MODVER})"

# amdgpu-dkms-firmware is a dependency of amdgpu-dkms, so purging the latter
# makes it an autoremove candidate -- and it is the package carrying every real
# gc_12_1_0 blob the emulated device needs.  Marked manual so autoremove below
# cannot take it.
sudo apt-mark manual amdgpu-dkms-firmware
AMDGPU_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms)
FW_PKG=$(dpkg-query -W -f='${Version}' amdgpu-dkms-firmware)
${APT} purge -y amdgpu-dkms
sudo rm -rf /usr/src/amdgpu-* /var/lib/dkms

# Back where modprobe looks.  depmod rather than trusting the postrm to have
# left modules.dep alone: it did run "dkms remove", and that rewrites it.
sudo install -d -m 0755 "/lib/modules/${KVER}/updates/dkms"
sudo cp -a "/var/tmp/slim-save/${AMDGPU_BASENAME}" \
    "/lib/modules/${KVER}/updates/dkms/${AMDGPU_BASENAME}"
sudo rm -rf /var/tmp/slim-save
sudo depmod -a "${KVER}"

# The assertion the whole section turns on.
RESTORED=$(modinfo -n amdgpu)
case "${RESTORED}" in
    */updates/dkms/*) ;;
    *)
        echo "Error: after the trim, modprobe resolves amdgpu to" \
             "${RESTORED:-<nothing>} rather than the restored DKMS module" >&2
        exit 1
        ;;
esac
test "$(modinfo -F version "${RESTORED}")" = "${AMDGPU_MODVER}"
test "$(modinfo -F firmware "${RESTORED}" | sort | tr '\n' ' ')" \
    = "${AMDGPU_FW_NAMES}"
modinfo -F parm "${RESTORED}" | grep -q '^emu_mode:'
echo "amdgpu.ko: ${RESTORED} (version ${AMDGPU_MODVER}, source tree removed)"

# --- 2. kernels and firmware ---------------------------------------------
#
# The release keeps its own kernel installed beside the mainline pin, and this
# guest boots exactly one of them.  The other is a kernel, its modules, its
# headers and an initramfs nobody will ever select -- and it is also the thing
# grub could fall back to, which is the failure the fat flavour's pinned-kernel
# assertions exist to catch.  Removing it makes that unrepresentable.
#
# Matched on the version in the package name rather than on a list: the
# mainline .debs and the archive's are named differently and both shapes carry
# the version, so this keeps whatever "uname -r" says and purges the rest.
STALE=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-modules-*' \
    2>/dev/null | grep -v -- "${KVER}" || true)
if [ -n "${STALE}" ]; then
    echo "purging kernels that are not ${KVER}:"
    echo "${STALE}" | sed 's/^/  /'
    # shellcheck disable=SC2086
    ${APT} purge -y ${STALE}
fi

# Headers go wholesale: nothing builds a module in this guest any more, and
# section 1 already removed the only DKMS package that would have been
# triggered by their removal.
HEADERS=$(dpkg-query -W -f='${Package}\n' 'linux-headers-*' 2>/dev/null || true)
if [ -n "${HEADERS}" ]; then
    # shellcheck disable=SC2086
    ${APT} purge -y ${HEADERS}
fi
sudo rm -rf /usr/src/linux-headers-*

# linux-firmware is microcode for hardware that cannot exist here -- when the
# image has it at all.  It was assumed to be ~1.5 GB of the guest and it is not
# in it: the cloud image's linux-image-virtual does not pull it and the mainline
# .debs do not either, so on this flavour this is a no-op.  Left in because a
# release that starts shipping it should still lose it, and recorded in the JSON
# below as what actually happened rather than as an asserted saving.
FW_REMOVED=false
if dpkg-query -W -f='${Status}' linux-firmware 2>/dev/null |
        grep -q '^install ok installed$'; then
    ${APT} purge -y linux-firmware
    FW_REMOVED=true
fi

${APT} autoremove --purge -y

# One kernel, and it is the one running.
KERNELS=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)
test "${KERNELS}" -eq 1
test -e "/boot/vmlinuz-${KVER}"

# --- 3. the toolchain ----------------------------------------------------
#
# Everything in packages/ernic-rocjitsu.txt that exists to *build* something.
# The manifest still asks for all of it, because the fat provision script this
# flavour reuses needs it to build amdgpu; build-vm.sh skips its
# package-presence assertion for a trimmed flavour for exactly this reason.
#
# dkms is in this list and not in section 1, and the order is not a style
# choice: amdgpu-dkms's postrm invokes the dkms binary, so purging dkms first
# leaves that package half-removed and the build dead at a dpkg error.
#
# Kept, deliberately: rdma-core, ibverbs-utils and perftest (the ionic half is
# the point of the flavour, and ib_send_bw and friends are runtime tools),
# pciutils, nvme-cli, kmod, initramfs-tools, curl, ca-certificates and the base
# python3 -- megabytes, all of them, and each one is something a consumer would
# otherwise have to install over SSH in a guest with no compiler.
# dpkg-dev is in the list for a reason that is not obvious: it Depends "make",
# so purging make without it makes apt satisfy that dependency by *installing*
# make-guile, which ships /usr/bin/make.  A trim that installs a compiler-
# adjacent package is bad enough; the checks' no-toolchain loop would then have
# failed the verification boot, twelve minutes later, on a package this script
# caused to appear.
purge_installed \
    build-essential g++ gcc cpp make dpkg-dev cmake ninja-build pkg-config \
    dkms git \
    python3-dev python3-docutils libstdc++-14-dev \
    libdrm-dev libssl-dev libcli11-dev libnl-3-dev libnl-route-3-dev \
    libudev-dev libsystemd-dev libibverbs-dev \
    pipx python3-venv rsync

# The compiler packages above are metapackages and versioned names both; take
# whatever is left of either.
#
# gcc-<n>-base is excluded: it is not a compiler, it is what libstdc++6 and
# libgcc-s1 depend on, and purging it takes the C++ runtime -- and therefore
# the HIP runtime this flavour exists to ship -- with it.
#
# Every *-dev name is excluded for a related reason, and this one failed a
# build rather than being reasoned out in advance: amdrocm-llvm10.1 Depends
# "libstdc++-5-dev|...|libstdc++-15-dev" and "libgcc-5-dev|...|libgcc-15-dev",
# and amdrocm-runtime10.1 Depends amdrocm-llvm10.1 -- so that or-group is held
# by the HIP runtime itself and survives every ROCm -dev purge in section 3b.
# libstdc++-15-dev is the installed satisfier; it pulls libgcc-15-dev and
# libc6-dev, and libc6-dev (with liburing-dev) pulls linux-libc-dev.  Naming
# any of them here makes a kept package uninstallable, and apt fails the entire
# transaction -- "E: Solver timed out" with no package named, which is a slow
# way to learn this.  The chain is tens of MB against a multi-GB saving.
#
# libgcc-14-dev is likewise left alone: libgccjit0 needs it, and emacs-nox --
# which qemu-minimal's default manifest installs -- needs libgccjit0.
LEFTOVER=$(dpkg-query -W -f='${Package} ${Status}\n' 'gcc-*' 'g++-*' 'cpp-*' \
    2>/dev/null |
    grep ' install ok installed$' | cut -d' ' -f1 |
    grep -vE -- '(-base|-dev)$' || true)
if [ -n "${LEFTOVER}" ]; then
    echo "purging:" "${LEFTOVER}"
    # shellcheck disable=SC2086
    ${APT} purge -y ${LEFTOVER}
fi

# Purging the toolchain takes ubuntu-standard and ubuntu-server with it -- they
# Depend rsync and git -- which turns a good deal of the base system into
# autoremove garbage, including the runtime tools this flavour promises and the
# libdrm stack the GPU half links.  Nothing in the ROCm package graph declares
# libdrm, so apt would take it without complaint and only a consumer's HIP
# binary would notice.  Pin what must survive, the way section 1 pins
# amdgpu-dkms-firmware, and guard each name so an archive rename cannot kill
# the trim.
for _keep in rdma-core ibverbs-utils perftest pciutils nvme-cli kmod \
             initramfs-tools curl ca-certificates python3 cloud-guest-utils \
             libdrm2 libdrm-amdgpu1 libpciaccess0 libnuma1 libelf1; do
    if dpkg-query -W -f='${Status}' "${_keep}" 2>/dev/null |
            grep -q '^install ok installed$'; then
        sudo apt-mark manual "${_keep}" > /dev/null
    fi
done
${APT} autoremove --purge -y

# A provider apt substitutes *during* a transaction cannot be filtered out
# before it, so make-guile is purged here rather than guarded against above.
purge_installed make make-guile guile-3.0-libs
if command -v make > /dev/null 2>&1; then
    echo "Error: make survived the trim ($(command -v make)); something here" \
         "still depends on it" >&2
    exit 1
fi

# --- 3b. ROCm's build half, as packages ----------------------------------
#
# ~2 GB, removed by dpkg rather than file by file: amdrocm-llvm-dev alone
# unpacks 2051213 KB of static archives and headers.  This is the saving the
# first version of this script tried to take with rm -rf, and taking it as
# packages is both larger and honest.
#
# The set installed by provision/ernic-rocjitsu.sh resolves to eight packages.
# Nothing installed reverse-depends on these four outside the set itself
# (blas-dev -> runtime-dev -> llvm-dev, plus hipblas-common-dev), so the purge
# is satisfiable and what remains is {sysdeps, base, llvm, runtime} -- which is
# what carries libamdhip64, libhsa-runtime64, libamd_comgr and the bitcode.
#
# All four of those arrived as dependencies rather than by hand, so purging the
# manual roots above them makes the whole ROCm half an autoremove candidate.
# The apt-mark is the same defence section 1 gives amdgpu-dkms-firmware, and
# the assertion after it is there because an autoremove that quietly took
# amdrocm-runtime would leave a guest that passes every ldconfig check in the
# checks file and runs nothing.
#
# amdsmi is in the keep list rather than merely surviving by accident.  It was
# installed by hand so it is already apt-mark manual and autoremove cannot take
# it today -- but it is the only per-device health tool the image has, it is
# runtime rather than toolchain, and the checks assert it, so it belongs where
# a future edit to this section will see it.
ROCM_KEEP="amdrocm-sysdeps${ROCM_VERSION} amdrocm-base${ROCM_VERSION} \
amdrocm-llvm${ROCM_VERSION} amdrocm-runtime${ROCM_VERSION} \
amdrocm-amdsmi${ROCM_VERSION}"
# Guarded one at a time rather than in one apt-mark: a name that has moved
# should fail at the assertion below, which says what is missing and why it
# matters, and not at an exit code from apt-mark.
for _pkg in ${ROCM_KEEP}; do
    if dpkg-query -W -f='${Status}' "${_pkg}" 2>/dev/null |
            grep -q '^install ok installed$'; then
        sudo apt-mark manual "${_pkg}" > /dev/null
    fi
done
purge_installed "amdrocm-blas-dev${ROCM_VERSION}" \
    "amdrocm-hipblas-common-dev${ROCM_VERSION}" \
    "amdrocm-runtime-dev${ROCM_VERSION}" "amdrocm-llvm-dev${ROCM_VERSION}"
${APT} autoremove --purge -y
for _pkg in ${ROCM_KEEP}; do
    if ! dpkg-query -W -f='${Status}' "${_pkg}" 2>/dev/null |
            grep -q '^install ok installed$'; then
        echo "Error: ${_pkg} is not installed after the ROCm -dev purge; the" \
             "HIP runtime this flavour ships comes from it" >&2
        exit 1
    fi
done

# --- 4. ROCm, runtime only -----------------------------------------------
#
# What is left after 3b is the runtime half: amdrocm-runtime ships
# ${ROCM_PATH}/lib/libamdhip64.so.*, libhsa-runtime64.so.* and
# libamd_comgr.so.* with their unversioned symlinks, so dlopen by bare name
# keeps working.  What this section removes is what survives inside
# amdrocm-llvm, which cannot be purged because the runtime depends on it.
#
# These are dpkg-owned paths, so dpkg -V will report them missing.  That is a
# deliberate, recorded property of a slim guest rather than damage: see
# /etc/slim-trim.json below.
#
# lib/llvm is TRIMMED, NOT DELETED, and the reason is a hard link rather than a
# preference: libamdhip64 has DT_NEEDED libamd_comgr, comgr has DT_NEEDED
# libLLVM and libclang-cpp and finds them through RPATH $ORIGIN/llvm/lib, and
# ${ROCM_PATH}/amdgcn is a *symlink* into lib/llvm/amdgcn, where the device
# bitcode lives.  Deleting the directory outright -- which is what the first
# version of this script did -- leaves a guest whose every HIP binary dies in
# the dynamic loader while "ldconfig -p" still cheerfully reports libamdhip64,
# because a cache lookup is not a resolution.
test -n "${ROCM_PATH}"
test -d "${ROCM_PATH}"
ROCM_DELETED=""
for d in include lib/cmake share/doc share/man lib/rocmcc; do
    if [ -e "${ROCM_PATH}/${d}" ]; then
        sudo rm -rf "${ROCM_PATH:?}/${d}"
        ROCM_DELETED="${ROCM_DELETED}${ROCM_DELETED:+,}\"${d}\""
    fi
done

# Keep exactly what comgr reaches, plus the bitcode beside it.  libMLIR and
# libclang are the bulk of what goes and nothing installed reaches either.
# Matched by glob rather than by soname: the version suffix is TheRock's, and
# readelf is gone by this point anyway.
sudo rm -rf "${ROCM_PATH:?}/lib/llvm/bin" "${ROCM_PATH:?}/lib/llvm/include"
sudo find "${ROCM_PATH:?}/lib/llvm" -mindepth 1 -maxdepth 1 \
    ! -name amdgcn ! -name lib -exec rm -rf {} +
sudo find "${ROCM_PATH:?}/lib/llvm/lib" -mindepth 1 -maxdepth 1 \
    ! -name 'libLLVM.so*' ! -name 'libclang-cpp.so*' -exec rm -rf {} +
ROCM_DELETED="${ROCM_DELETED}${ROCM_DELETED:+,}\"lib/llvm (kept: amdgcn, libLLVM.so*, libclang-cpp.so*)\""

# The compiler drivers are standalone executables in bin/ shipped by the kept
# amdrocm-llvm, not symlinks into the tree just deleted, so nothing above
# removes them -- and WELCOME.md's "hipcc is not here" would be a lie on a
# login PATH that includes ${ROCM_PATH}/bin.
if [ -d "${ROCM_PATH}/bin" ]; then
    for b in hipcc hipcc.bin hipcc.pl hipconfig hipconfig.bin hipconfig.pl \
             hipcc_cmake_linker_helper amdclang amdclang++ amdclang-cl \
             amdclang-cpp amdflang amdlld amdllvm offload-arch; do
        sudo rm -f "${ROCM_PATH:?}/bin/${b}"
    done
    # And anything else that pointed into the deleted lib/llvm/bin.
    sudo find "${ROCM_PATH:?}/bin" -xtype l -delete
    for b in hipcc hipconfig amdclang++; do
        if [ -e "${ROCM_PATH}/bin/${b}" ]; then
            echo "Error: ${ROCM_PATH}/bin/${b} survived the trim; the slim" \
                 "checks assert it is absent from the login PATH" >&2
            exit 1
        fi
    done
fi

sudo find "${ROCM_PATH}" -name '*.a' -delete
sudo ldconfig

# The device bitcode the runtime loads at dispatch, asserted here so a future
# edit to the deletion list fails with the cause on screen instead of in a
# consumer's first hipMalloc.
test -d "${ROCM_PATH}/lib/llvm/amdgcn/bitcode"
test -d "${ROCM_PATH}/amdgcn"
test -s "${ROCM_PATH}/amdgcn/bitcode/ockl.bc"
test -s "${ROCM_PATH}/amdgcn/bitcode/hip.bc"
test -n "$(ls "${ROCM_PATH}"/amdgcn/bitcode/oclc_*.bc 2>/dev/null)"

# Resolution, not presence.  This is the assertion that would have caught the
# lib/llvm deletion above: ldconfig reads a cache and passes happily for a
# library whose NEEDED entries are no longer on disk.  ldd resolves them, and
# it is transitive, so it covers comgr reaching into lib/llvm as well.
for _lib in libamdhip64 libhsa-runtime64; do
    _so=$(ldconfig -p | awk -v l="${_lib}\\.so" '$0 ~ l {print $NF; exit}')
    test -n "${_so}"
    if ldd "${_so}" 2>&1 | grep -q 'not found'; then
        echo "Error: ${_so} has unresolved dependencies after the trim:" >&2
        ldd "${_so}" 2>&1 | grep 'not found' >&2
        exit 1
    fi
done

# --- 4b. the ionic SRQ stack ---------------------------------------------
#
# Nothing above sets out to remove any of this, which is exactly why it is
# checked here.  The SRQ stack is two artefacts with two different owners --
# the ionic-ernic DKMS modules under updates/dkms, and a whole rdma-core in
# /usr/local -- and both sit in the blast radius of steps aimed at something
# else: section 1 deletes /var/lib/dkms wholesale, section 3 purges the
# toolchain and lets autoremove take what is then unreferenced, and either
# could plausibly grow to take these.
#
# A guest that loses them does not look broken.  It boots, ibv_devinfo works,
# every other assertion in this script passes, and the only symptom is
# max_srq = 0 in a consumer's job days later, where it reads as a device or a
# server-version problem rather than as a trim.  This is the cheap place to
# find out.
#
# No nm here, unlike the playbook that built it: binutils went with the
# toolchain in section 3.  The symbol check belongs to the build, which ran
# while a compiler still existed; this asserts the artefacts survived.
SRQ_STAMP=/etc/ionic-srq.json
if [ -f "${SRQ_STAMP}" ]; then
    IONIC_KO=$(modinfo -n ionic_rdma)
    case "${IONIC_KO}" in
        */updates/dkms/*) ;;
        *)
            echo "Error: after the trim, modprobe resolves ionic_rdma to" \
                 "${IONIC_KO:-<nothing>} rather than the SRQ-capable DKMS" \
                 "module. ${SRQ_STAMP} says this guest has one." >&2
            exit 1
            ;;
    esac
    # The userspace half.  Presence and resolution both: a /usr/local
    # libibverbs whose NEEDED entries went with an autoremove leaves every
    # verbs tool broken in a guest where the file is still there.
    ls /usr/local/lib/libibverbs/libionic-rdmav*.so > /dev/null
    IBV=$(command -v ibv_devinfo)
    if ! ldd "${IBV}" | grep -q '/usr/local/lib/libibverbs'; then
        echo "Error: ${IBV} no longer resolves the /usr/local libibverbs;" \
             "the SRQ provider is installed but not the one that loads." >&2
        ldd "${IBV}" >&2
        exit 1
    fi
    if ldd "${IBV}" 2>&1 | grep -q 'not found'; then
        echo "Error: ${IBV} has unresolved dependencies after the trim:" >&2
        ldd "${IBV}" 2>&1 | grep 'not found' >&2
        exit 1
    fi
    SRQ_KEPT=true
    echo "ionic SRQ stack: ${IONIC_KO}, provider in /usr/local"
else
    # Not an error.  trim/slim.sh is flavour-agnostic machinery and a future
    # flavour may run it over a guest with no SRQ stack at all; what must not
    # happen is a guest that had one and lost it, which is the branch above.
    SRQ_KEPT=false
    echo "no ${SRQ_STAMP}; this guest was built without the SRQ stack"
fi

# --- 5. boot speed -------------------------------------------------------
#
# cloud-init is disabled rather than purged.  Its job here is done -- the user,
# the key and /etc/netplan/50-cloud-init.yaml were all written during the fat
# build and are plain files on disk -- but its purge hooks reach into
# /etc/cloud and /var/lib/cloud, and the netplan file is what gives this guest
# an address.  Masking costs a few MB and cannot take the network with it.
#
# The consequence for a consumer is real and is documented: no seed ISO, no
# NoCloud userdata, no injecting an SSH key at launch.  The baked-in login and
# the keypair published beside the image are how you get in.
#
# cloud-init.service is only an Alias of cloud-init-network.service on this
# release, and systemd refuses to mask an alias -- which the "|| true" would
# have swallowed, leaving the network stage running in a guest advertised as
# having cloud-init disabled.  Both spellings are listed; the one that is not
# a unit here is the one the error is discarded for.
sudo touch /etc/cloud/cloud-init.disabled
sudo systemctl mask cloud-init-local.service cloud-init-network.service \
    cloud-config.service cloud-final.service cloud-init.target \
    2>/dev/null || true

purge_installed snapd modemmanager packagekit apport whoopsie \
    multipath-tools lxd-installer
sudo rm -rf /var/lib/snapd /snap /var/cache/snapd

# systemd-networkd-wait-online is the classic silent stall: it blocks boot for
# up to two minutes waiting on an interface that is already configured.
for unit in systemd-networkd-wait-online.service \
            NetworkManager-wait-online.service \
            e2scrub_all.timer e2scrub_reap.service man-db.timer \
            motd-news.timer apt-daily.timer apt-daily-upgrade.timer; do
    sudo systemctl mask "${unit}" 2>/dev/null || true
done

# A file of its own rather than an edit to /etc/default/grub, for the reason
# every other grub change in this repo uses one: 50-cloudimg-settings.cfg is
# sourced afterwards and would overwrite it.  Separate from
# 99-pinned-kernel.cfg, which owns GRUB_DEFAULT -- different variables, both
# sourced, neither clobbering the other.
#
# GRUB_RECORDFAIL_TIMEOUT matters as much as GRUB_TIMEOUT: without it an
# unclean shutdown -- which is how a CI guest usually ends -- makes the *next*
# boot sit at the menu for 30 seconds.
sudo install -d -m 0755 /etc/default/grub.d
sudo tee /etc/default/grub.d/99-slim-fastboot.cfg > /dev/null <<'EOF'
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
EOF

# Rebuild every initramfs, so the amdgpu-exclude hook from provisioning is
# proved to still run -- the "no amdgpu.ko in any initrd" assertion in the
# checks is what that is worth.
#
# Deliberately no MODULES= override.  MODULES=dep reads like free savings and
# is not: it walks the *build-time* /sys and keeps only what this machine
# needed, so the verification boot -- same topology, same command line -- goes
# green and a consumer whose root disk is NVMe or AHCI drops to an initramfs
# shell.  On this kernel that is the whole of the exposure and it is still
# real: mainline 7.2.4 has CONFIG_VIRTIO_PCI, VIRTIO_BLK, SCSI_VIRTIO and
# EXT4_FS built in, so the virtio path survives any pruning, while
# BLK_DEV_NVME and SATA_AHCI are modules and would not.  Its mount helper also
# exits 1 outright when blkid cannot resolve /, which under "set -eu" is a lost
# build with no fallback.  The initramfs is tens of MB; the guest it can strand
# is the whole artifact.
sudo update-initramfs -u -k all
sudo update-grub
# The pinned-kernel default and the amdgpu blacklist both have to survive a
# regenerated grub.cfg; build-vm's probe asserts the first, this asserts the
# second while the cause is still on screen.
sudo grep -q 'modprobe.blacklist=amdgpu' /boot/grub/grub.cfg

# --- 6. caches, docs, logs -----------------------------------------------
#
# The path-excludes are for anything a consumer installs later; the rm is for
# what is already here.  Both, because either alone leaves most of it.
sudo tee /etc/dpkg/dpkg.cfg.d/01-slim-no-docs > /dev/null <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/lintian/*
path-include /usr/share/doc/*/copyright
EOF
sudo rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
    /usr/share/lintian /usr/share/help
# Keep English; the rest is a few hundred MB of translations for a guest whose
# entire user interface is an SSH session from a CI job.
sudo find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
    ! -name 'en*' -exec rm -rf {} +

${APT} clean
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    /var/tmp/* /tmp/* /home/"${USERNAME}"/.cache
sudo journalctl --rotate --vacuum-size=1M 2>/dev/null || true
sudo rm -rf /var/log/journal/* /var/lib/systemd/coredump/*
sudo find /var/log -type f -exec truncate -s 0 {} +

# --- 7. the record, and the discard --------------------------------------
#
# What was taken out, where a consumer inside the guest can read it.  This is
# the file to check before assuming a guest can build something: the flavour
# name says "slim", but the detail of what that meant on the day it was built
# lives here.
USED_AFTER=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
sudo tee /etc/slim-trim.json > /dev/null <<EOF
{
  "flavour": "${FLAVOUR}",
  "trim": "slim.sh",
  "in_guest_builds": false,
  "cloud_init": "disabled",
  "booted_kernel": "${KVER}",
  "kernels_installed": 1,
  "amdgpu_dkms_package": "${AMDGPU_PKG}",
  "amdgpu_dkms_firmware_package": "${FW_PKG}",
  "amdgpu_module_version": "${AMDGPU_MODVER}",
  "amdgpu_module_source_removed": true,
  "rocm_path": "${ROCM_PATH}",
  "rocm_subtrees_removed": [${ROCM_DELETED}],
  "rocm_packages_purged": ["amdrocm-blas-dev${ROCM_VERSION}",
                           "amdrocm-hipblas-common-dev${ROCM_VERSION}",
                           "amdrocm-runtime-dev${ROCM_VERSION}",
                           "amdrocm-llvm-dev${ROCM_VERSION}"],
  "linux_firmware_removed": ${FW_REMOVED},
  "ionic_srq_stack_kept": ${SRQ_KEPT},
  "snapd_removed": true,
  "root_used_mib_before": ${USED_BEFORE},
  "root_used_mib_after": ${USED_AFTER}
}
EOF
sudo chmod 0644 /etc/slim-trim.json
cat /etc/slim-trim.json

# Appended to the note the provision script already wrote, rather than a second
# file: someone who has just logged in reads one thing, and what it says about
# the two devices is still true.
tee -a "/home/${USERNAME}/WELCOME.md" > /dev/null <<EOF

## This is the slim guest

Built from the same recipe as \`ernic-rocjitsu\` and then trimmed by
\`trim/slim.sh\`. The kernel, the patched \`amdgpu\`, the firmware and the ionic
half are identical. What is gone:

- **The toolchain.** No gcc, no cmake, no kernel headers, no DKMS. This guest
  cannot build \`ionic-ernic\`, or anything else. Use the fat
  \`ernic-rocjitsu\` flavour for a lane that compiles in-guest.
- **The amdgpu DKMS source.** The patched module is installed and is what
  \`modprobe\` picks; it cannot be rebuilt here, so do not install a kernel.
- **ROCm's compilers and headers.** The HIP runtime is here and a prebuilt HIP
  binary runs; \`hipcc\`, \`amdclang\` and every ROCm header are gone. LLVM
  survives only as the two shared libraries \`libamd_comgr\` links against,
  and the device bitcode beside them.
- **cloud-init is disabled.** No seed ISO, no userdata, no key injection at
  launch -- log in as \`${USERNAME}\` with the published keypair.
- **No growpart.** cloud-init is what grew the root filesystem on first boot,
  so resizing the qcow2 no longer resizes the guest. After a
  \`qemu-img resize\`, run \`sudo growpart /dev/vda 1 && sudo resize2fs
  /dev/vda1\` once inside the guest.
- linux-firmware, snapd, docs, man pages and every apt cache.

What is **not** gone, and is worth knowing because it cannot be rebuilt here:
the ionic SRQ stack. The \`ionic-ernic\` DKMS modules under \`updates/dkms\`
and the patched rdma-core in \`/usr/local\` both survive the trim, and
\`/etc/ionic-srq.json\` still records what they were built from. The DKMS
*source* and the compiler are gone, so a kernel installed in this guest would
have neither a GPU driver nor an SRQ-capable ionic -- use the fat
\`ernic-rocjitsu\` flavour for any lane that needs to rebuild either.

\`/etc/slim-trim.json\` is the machine-readable version of this list.
EOF
chmod 0644 "/home/${USERNAME}/WELCOME.md"

echo "root filesystem used: ${USED_BEFORE} -> ${USED_AFTER} MiB"

# And give the freed space back to the qcow2.  probe-guest attaches the disk
# with discard=unmap, so this reaches the image file rather than stopping at
# the guest filesystem; build-vm's convert afterwards is what rewrites it
# compactly.
sudo fstrim -av
