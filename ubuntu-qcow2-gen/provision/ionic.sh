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
