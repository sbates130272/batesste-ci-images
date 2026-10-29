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

# Verbs userspace is present.
command -v ibv_devinfo

# What the ionic stack looks like depends on whether a post-provision
# playbook ran, so this branches on the evidence rather than on an assumption.
#
# With no post_playbook the guest carries the in-tree ionic from its own
# kernel and nothing built -- which is what this flavour has shipped for most
# of its life. It ships the DKMS form now: vm-ernic-srq-p4.yml builds ionic
# once with patches/srq and patches/p4 combined, and builds ernic_p4.ko
# against that same tree. The branch stays because the empty case was real
# until 2026-10-29 -- vm-ernic-p4.yml needed an emulated NIC on the bus that
# an image build does not have -- and a flavour can be configured either way.
#
# With one, ernic_guest_setup rebuilds ionic-ernic and installs both halves
# into updates/dkms, displacing the in-tree modules, and ernic_p4_dkms adds
# ernic_p4.ko.
#
# Branching on /etc/ionic-srq-p4.json, not on modinfo output: the stamp is written
# by the playbook and is the only thing here that says what was *intended*.
# Deciding from modinfo would make this check agree with whatever the image
# happens to contain, which is not a test.
#
# This file asserted the DKMS form unconditionally for one build. That was
# written for a post_playbook that was then reverted, and the check was not
# revisited -- it failed bake 68210285 in the verification boot, correctly, on
# an image that was right.
if [ -s /etc/ionic-srq-p4.json ]; then
    echo "ionic: post-playbook stamp present; expecting the DKMS stack"
    for _m in ionic ionic_rdma ernic_p4; do
        _ko=$(modinfo -n "${_m}")
        case "${_ko}" in
            */updates/dkms/*) echo "  ${_m}: ${_ko}" ;;
            *)
                echo "ERROR: /etc/ionic-srq-p4.json says this guest was built" \
                     "with vm-ernic-srq-p4.yml, but modprobe would load" \
                     "${_ko:-nothing} for ${_m} rather than a DKMS module" >&2
                exit 1
                ;;
        esac
    done
    python3 -c 'import json;print("  stamp:", json.dumps(json.load(open("/etc/ionic-srq-p4.json")), sort_keys=True)[:200])'
else
    # No playbook ran. The in-tree ionic_rdma is the contract, and the reason
    # this flavour exists: drivers/infiniband/hw/ionic merged in 6.18, so a
    # consuming job can build ionic-ernic against it without building a
    # kernel first.
    echo "ionic: no post-playbook stamp; expecting the in-tree driver"
    for _m in ionic ionic_rdma; do
        _ko=$(modinfo -n "${_m}")
        case "${_ko}" in
            */updates/dkms/*)
                echo "ERROR: ${_m} resolves to ${_ko}, a DKMS module, but no" \
                     "/etc/ionic-srq-p4.json says a playbook installed one." \
                     "Something built a driver this flavour does not track." >&2
                exit 1
                ;;
            "") echo "ERROR: no module found for ${_m}" >&2; exit 1 ;;
            *)  echo "  ${_m}: ${_ko}" ;;
        esac
    done
fi

# No ionic module in any initramfs, asserted against the FINISHED image.
#
# This runs in the verification boot, which is the only place that sees the
# final state: the DKMS pair is installed by the post-provision playbook and
# the kernel trim runs after that, both later than any provision script. The
# hook that prevents this lives in provision/ionic.sh; this is what proves it
# took.
#
# Why it matters: a stale in-tree ionic.ko in the initramfs loads before any
# rootfs modules.dep is consulted, so ionic_rdma -- built against the patched
# DKMS ionic -- fails on a symbol version mismatch, and nothing in that
# failure names the initramfs. It shipped that way for weeks.
#
# Written as an if/exit rather than `! lsinitramfs ... | grep -q`: a command
# whose status is inverted with `!` never trips `set -e`.
for _img in /boot/initrd.img-*; do
    [ -e "${_img}" ] || continue
    if lsinitramfs "${_img}" | grep -qE '(^|/)(ionic|ionic_rdma|ernic_p4)\.ko(\.[a-z]+)?$'; then
        echo "ERROR: an ionic module is present in ${_img}" >&2
        echo "       the initramfs would load it before the DKMS pair on the" >&2
        echo "       rootfs, and ionic_rdma would fail on a symbol version" >&2
        echo "       mismatch. See /etc/initramfs-tools/hooks/ionic-exclude" >&2
        lsinitramfs "${_img}" | grep -E 'ionic|ernic_p4' >&2 || true
        exit 1
    fi
done
echo "initramfs: no ionic modules in $(ls -1 /boot/initrd.img-* | wc -l) image(s)"
