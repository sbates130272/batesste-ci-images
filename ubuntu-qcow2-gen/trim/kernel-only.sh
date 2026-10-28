# shellcheck shell=bash
#
# Remove the release kernel the cloud image came with, and nothing else.
#
# This is trim/slim.sh's section 2 and none of the rest of it. slim.sh exists
# to take the toolchain back out of a guest that has finished building things;
# this exists only to leave one kernel installed. A flavour using this still
# ships its compiler, its headers and its DKMS trees, because the jobs that
# consume it build ionic-ernic in-guest against the kernel it boots.
#
# Why bother, when grub is already pinned: the pin is an assertion that the
# right kernel is chosen, and this makes choosing the wrong one impossible.
# build-vm.sh pins GRUB_DEFAULT by menuentry id and then verifies that the
# generated grub.cfg really carries it -- three separate failure messages,
# all of them guarding against booting the release's 7.0.x instead of the
# mainline pin. With one kernel installed there is nothing to guard.
#
# What it recovers, measured on ernic-rocjitsu (resolute, kernel_ref v7.2.6):
#
#   linux-modules-7.0.0-30-generic    163 MB
#   linux-headers-7.0.0-30             92 MB
#   linux-headers-7.0.0-30-generic     32 MB
#   linux-image-7.0.0-30-generic       17 MB
#   /boot/initrd.img-7.0.0-30-generic  64 MB   (generated, goes with the purge)
#   ------------------------------------------
#                                     368 MB
#
# Runs in a boot of its own, after provisioning and before the verification
# boot, so the checks see the single-kernel state rather than a promise of it.

# No `set` line: build-vm.sh prepends `set -eu` and the flavour's variables
# before concatenating this file, and runs the result through `bash -s`.
# Adding pipefail here would differ from slim.sh for no reason.

KVER=$(uname -r)
# The ABI without the flavour suffix. Matching on the full "uname -r" is wrong
# here and is the one thing this does differently from slim.sh: the shared
# header package is linux-headers-7.2.6-070206, with no "-generic", so a
# grep -v on the full release string would purge the very package that
# /lib/modules/<KVER>/build points into -- and the checks assert that path
# exists. slim.sh gets away with the full string because it purges every
# header package regardless.
KABI=${KVER%-generic}

echo "kernel: ${KVER}  (abi ${KABI})"

APT="sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120"

# Everything versioned at some other ABI, plus the unversioned metapackages.
# linux-image-virtual, linux-headers-generic and linux-headers-virtual carry no
# version, so they fall out of this filter on their own -- which is what we
# want: they are what would pull a release kernel back in on the next
# apt-get upgrade, and they are satisfied by the archive's kernel rather than
# by the mainline .debs, which are unsigned and named differently.
STALE=$(dpkg-query -W -f='${Package}\n' \
    'linux-image-*' 'linux-modules-*' 'linux-headers-*' 2>/dev/null \
    | grep -v -- "${KABI}" || true)

if [ -z "${STALE}" ]; then
    echo "no kernel packages to purge; already down to ${KVER}"
else
    echo "purging kernel packages that are not ${KABI}:"
    echo "${STALE}" | sed 's/^/  /'
    # shellcheck disable=SC2086
    ${APT} purge -y ${STALE}
fi

# A stray initramfs built for a kernel called "added".
#
# Something in the amdgpu-dkms install path calls update-initramfs with a bad
# -k argument: the build log carries "depmod: ERROR: Bad version passed added"
# and a cat of /var/tmp/mkinitramfs_*/lib/modules/added/modules.builtin that
# cannot exist, and what lands is /boot/initrd.img-added -- 29 MB for a kernel
# that was never installed. No grub entry references it, nothing regenerates
# it, and update-initramfs -d cannot remove it because "added" is not a kernel
# it knows. Deleted by name.
#
# Removed here rather than fixed because the call is upstream of this repo.
if [ -f /boot/initrd.img-added ]; then
    echo "removing /boot/initrd.img-added ($(sudo du -h /boot/initrd.img-added | cut -f1))"
    sudo rm -f /boot/initrd.img-added
fi

${APT} autoremove -y --purge
sudo update-grub

# What is left, said out loud: this is the line a reader checks when the guest
# boots something unexpected, and it costs nothing to print.
echo "kernels remaining:"
dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-modules-*' \
    'linux-headers-*' 2>/dev/null | sed 's/^/  /'
ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/|  /boot/|'

# The headers the consuming jobs build against have to have survived. Asserted
# here, where the purge that would have broken it is still on screen, as well
# as in checks/.
test -d /lib/modules/"${KVER}"/build
echo "headers intact: /lib/modules/${KVER}/build"
