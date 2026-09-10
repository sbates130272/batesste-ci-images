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

# Headroom for a kernel tree, rdma-core and the DKMS builds.
test "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 20
