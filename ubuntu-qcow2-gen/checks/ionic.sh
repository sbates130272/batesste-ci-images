# shellcheck shell=bash
#
# Assertions run inside the "ionic" guest during the build's probe boot.
# Appended to a "set -eu" bash script, so any failing command fails the build.

# The reason this flavour exists: drivers/infiniband/hw/ionic merged in Linux
# 6.18. Compare the whole version tuple, not major-and-minor separately --
# "major >= 6 and minor >= 18" rejects 7.0, which is the most likely way a
# correct image still looks wrong.
test "$(printf '6.18\n%s\n' "$(uname -r)" | sort -V | head -1)" = "6.18"

# Headers matching the running kernel, so DKMS can build against them.
test -d /lib/modules/"$(uname -r)"/build

# The 6.18 floor is necessary and not sufficient: ionic-ernic v7.2.4 calls
# ib_umem_get_va, added after 7.0, and a guest without it fails at compile time
# in the consumer's job rather than here. Assert the symbol, not just a number.
grep -q ib_umem_get_va /lib/modules/"$(uname -r)"/build/include/rdma/ib_umem.h

# The toolchain and rdma-core build dependencies the consuming jobs skip
# installing because they are pre-baked here.
command -v gcc make cmake ninja dkms git
python3 -c 'import docutils'
pkg-config --exists libnl-3.0 libnl-route-3.0 libudev libsystemd

# Verbs userspace is present, and the ionic RDMA module ships with the guest
# kernel rather than needing to be built.
command -v ibv_devinfo
modinfo ionic_rdma > /dev/null

# providers/ionic, which is what makes the emulated NIC usable through
# libibverbs. Upstream first shipped it in v61 and resolute packages 61.0, so
# the archive supplies it. This is the role's own verification step, so a
# failure here is a failure it would have hit too. The provider carries the ABI
# suffix rather than a bare name -- libionic-rdmav59.so at 61.0 -- so match on
# the prefix.
ls /usr/lib/*/libibverbs/libionic*.so

# And it is still the packaged file. A source build installed over /usr leaves
# this same path in place while orphaning it from dpkg, which is the state this
# flavour deliberately does not create: nothing an apt upgrade can clobber, and
# so nothing to hold.
dpkg -S /usr/lib/*/libibverbs/libionic*.so > /dev/null

# The stamp ernic_guest_setup reads before deciding to build rdma-core itself.
# <version>:<gda-patch-hash>, where the hash is the literal "none" if no GDA
# direct-verbs patches were applied -- which is the case here on purpose, since
# every current lane passes ernic_gpu_passthrough=false and wants the unpatched
# build.
STAMP=$(cat /usr/local/share/rocm-ernic/provider.stamp)
test "${STAMP#*:}" = none

# No version literal in this file. The stamp has to describe the rdma-core that
# is actually installed, so compare it against dpkg rather than against a copy
# of the pin -- which the pin would satisfy even if the guest carried something
# else entirely.
INSTALLED=$(dpkg-query -W -f='${Version}' rdma-core)
test "${STAMP%%:*}" = "${INSTALLED%%-*}"

# Traffic generators for jobs that exercise the queue pairs. Name the read and
# write verbs separately: perftest splits across binaries and a partial install
# is the failure worth catching here.
command -v ib_send_bw ib_write_bw ib_read_bw ib_send_lat

# Headroom for a kernel tree, rdma-core and the DKMS builds.
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
