# shellcheck shell=bash
#
# In-guest provisioning for the "ionic" flavour, run by build-vm.sh in a
# PROBE_PERSIST boot after cloud-init and after the mainline kernel layer.
#
# Nothing is installed here.  resolute packages rdma-core 61.0, and its
# ibverbs-providers already carries libionic-rdmav59.so -- the userspace
# provider that makes the emulated NIC usable through libibverbs, and the only
# reason rocm-ernic's ernic_guest_setup role builds rdma-core from source at
# all.  The archive supplies it, so this flavour does not overwrite dpkg-owned
# paths under /usr, and needs no holds to defend the result from apt.
#
# What is left is the stamp that role reads before deciding to build.  It is
# not yet a skip: the role pins ernic_rdma_core_version at 62.0 and compares
# exactly, so a 61.0 stamp does not match and the lanes keep building -- and
# keep depending on the GitHub release CDN, which 500'd for that tarball on
# 2026-09-16 and failed a run during provisioning.  Writing the truth about
# what is installed is the half of that fix this repo owns; lowering the pin to
# 61.0, which satisfies the role's own ">= 61" assert, is the half rocm-ernic
# owns.  A stamp claiming 62.0 over a 61.0 install would buy the skip today and
# hand the role a provider built differently from the one it thinks it has.
#
# Appended to a preamble that sets "set -eu" and the values below, so any
# failing command fails the image build.  Runs as the guest user; root comes
# from sudo, which is the contract every flavour has.
#
# RDMA_CORE_VERSION comes from the preamble, pinned in images.yml.

echo "=== ionic guest provisioning ==="
echo "rdma-core: ${RDMA_CORE_VERSION}"

if [ -z "${RDMA_CORE_VERSION}" ]; then
    echo "Error: RDMA_CORE_VERSION is empty" >&2
    exit 1
fi

# The pin is an assertion about the release, not an instruction: the stamp has
# to describe what is actually installed, so read that and refuse to stamp
# anything else.  A release that moves its rdma-core fails the build here
# rather than publishing a guest whose stamp quietly disagrees with its
# libraries.
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

# The PCI ID database, refreshed rather than taken from the archive.
#
# Not guarded.  rocm-ernic's guest verification asserts from 9e4cb55 that the
# emulated NIC resolves to the official ionic ID and that its subsystem names
# match pci.ids, and the archive's stock database predates that entry -- so a
# swallowed failure here does not cost a cosmetic lspci label, it hands the
# consumer a guest that fails those checks with nothing in this build saying
# why.  update-pciids exits non-zero if it cannot fetch, and under "set -e"
# that is the image build failing where the cause is still visible.
sudo update-pciids

# RDMA pins memory, and this guest's default ceiling is 8192 KB.  The same two
# files provision/ernic-rocjitsu.sh writes, for the same reason and with the
# same wording: this flavour serves the same emulated ionic NIC, so it has the
# same ceiling, and it was simply missed when that one was fixed.
#
# What the limit costs is not obvious from the failure.  An unprivileged
# ib_send_bw above about 4 MiB dies with "Couldn't create CQ" -- two buffers
# plus the queue memory crossing 8 MiB -- and nothing in the message says
# memlock.  Past it every ibv_reg_mr() fails with "Cannot allocate memory",
# which UCX surfaces as a ud_recv_skb mpool failure and NIXL's libfabric
# plugin as "Failed to initialize control request pool for rail 0".  Running
# as root hides it, because CAP_IPC_LOCK bypasses RLIMIT_MEMLOCK -- and
# "ulimit -l" still reads 8192 under sudo, so the limit is easy to rule out
# incorrectly.
#
# Both files, because they cover callers the other cannot.  limits.d is PAM,
# so it reaches an SSH login and anything started from one; a systemd unit
# never goes through PAM's limits and takes DefaultLimitMEMLOCK instead.  A
# consumer running their RDMA binary from a unit file is the case that fails
# with only the first.
sudo install -d -m 0755 /etc/security/limits.d
sudo tee /etc/security/limits.d/99-rdma-memlock.conf > /dev/null <<'EOF'
# Unlimited locked memory for RDMA.  See provision/ionic.sh in
# batesste-ci-images.
*       soft    memlock     unlimited
*       hard    memlock     unlimited
root    soft    memlock     unlimited
root    hard    memlock     unlimited
EOF
sudo chmod 0644 /etc/security/limits.d/99-rdma-memlock.conf
sudo install -d -m 0755 /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/99-rdma-memlock.conf > /dev/null <<'EOF'
[Manager]
DefaultLimitMEMLOCK=infinity
EOF
sudo chmod 0644 /etc/systemd/system.conf.d/99-rdma-memlock.conf
# Not asserted here: both take effect at the next login and the next boot
# respectively, and this script is running inside the session they do not
# apply to.  checks/ionic.sh asserts "ulimit -l" in the verification boot,
# which is a fresh login on a rebooted guest -- the shape a consumer gets.

# Format is <version>:<gda-patch-hash>, with the literal string "none" when no
# GDA patches were applied.  The role applies its ionic GDA direct-verbs series
# only for GPU-passthrough guests and folds a hash of it in here in place of
# "none"; every current lane passes ernic_gpu_passthrough=false, so the
# unpatched value is the one worth writing.  A passthrough run does not match
# and rebuilds with the patches, which is correct.  The role compares the
# trimmed contents against a value it computes, so both the text and the
# trailing newline matter.
sudo install -d -m 0755 /usr/local/share/rocm-ernic
printf '%s:none\n' "${RDMA_CORE_VERSION}" |
    sudo tee /usr/local/share/rocm-ernic/provider.stamp > /dev/null
sudo chmod 0644 /usr/local/share/rocm-ernic/provider.stamp

# --- keep the in-tree ionic out of the initramfs --------------------------
#
# This flavour shipped with the in-tree ionic and nothing built until
# post_playbook gained vm-ernic-p4.yml, which installs a *patched* ionic pair
# into updates/dkms and displaces the in-tree modules. That is the same shape
# that broke ernic-rocjitsu, and it breaks the same way:
#
#   MODULES=most sweeps the stock in-tree ionic.ko into the initramfs at bake
#   time. The initramfs runs before any rootfs modules.dep is consulted, so
#   the stale module is resident first, and ionic_rdma -- built against the
#   patched one -- then fails to load on a symbol version mismatch. The
#   srcversions differ (4C88CEF against the DKMS build's 451442B); neither
#   `depmod -a` nor an /etc/modules-load.d entry helps, because depmod is
#   already correct and modules-load.d runs after the damage.
#
# Installed here even though the DKMS install happens later, in the
# post-provision playbook: a hook is a file, and it applies to every
# update-initramfs that runs after it -- including the playbook's. The
# matching assertion cannot live here for the same reason, because at this
# point there is nothing wrong yet; it is in checks/ionic.sh, which runs in
# the verification boot against the finished image.
#
# Dropping them is safe: root is on virtio and the emulated NIC is not a boot
# device. The DKMS pair then loads from the rootfs, where modules.dep already
# points at both halves.
sudo install -d -m 0755 /etc/initramfs-tools/hooks
sudo tee /etc/initramfs-tools/hooks/ionic-exclude > /dev/null <<'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "${PREREQ}"; }
case "${1}" in prereqs) prereqs; exit 0 ;; esac
[ -n "${DESTDIR}" ] || exit 0
# The queue first: at the time a hook runs the module has not been copied
# yet, it is pending in mkinitramfs' __MODULES_TO_ADD as a bare name, and the
# apply_add_modules *after* the hooks is what copies it. A find alone sees
# nothing. The find still runs, for the copies already staged.
if [ -n "${__MODULES_TO_ADD:-}" ] && [ -f "${__MODULES_TO_ADD}" ]; then
    grep -vxE 'ionic|ionic_rdma|ernic_p4' "${__MODULES_TO_ADD}" \
        > "${__MODULES_TO_ADD}.keep" || true
    mv "${__MODULES_TO_ADD}.keep" "${__MODULES_TO_ADD}"
fi
find "${DESTDIR}" -name 'ionic.ko*' -delete
find "${DESTDIR}" -name 'ionic_rdma.ko*' -delete
find "${DESTDIR}" -name 'ernic_p4.ko*' -delete
HOOK
sudo chmod 0755 /etc/initramfs-tools/hooks/ionic-exclude
sudo update-initramfs -u -k all
