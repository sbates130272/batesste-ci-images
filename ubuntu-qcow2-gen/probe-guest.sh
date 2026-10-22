#!/bin/sh
#
# probe-guest.sh
#
# Boot a freshly built guest qcow2, run a script inside it over SSH and print
# that script's stdout.  Used at build time to read facts out of the guest that
# are not knowable beforehand (the kernel version, above all) and to run the
# per-flavour checks, so a guest that cannot boot or is missing what it
# promised fails the build rather than the consumer.
#
#   probe-guest <image.qcow2> <username> <script> [payload-dir]
#
# The guest boots from a throwaway overlay, so the published image is byte-for
# byte what "qemu-tool gen-vm" produced -- probing must not be why an image
# differs.
#
# PROBE_PERSIST=1 boots the image itself instead, turning the same primitive
# into a provisioning pass: anything the script changes is kept.  Only for
# steps cloud-init cannot express, and never for the verification boot, which
# has to see the image a consumer will get.
#
# PROBE_ANSIBLE=1 makes <script> an Ansible playbook on the builder, run from
# here against the booted guest instead of piped into "bash -s".  The boot,
# the SSH wait, the serial capture and the poweroff are identical and are the
# reason this is a mode rather than a second script: a playbook pass that
# boots the guest differently from every other pass is one that can succeed
# where the real thing fails.  The caller installs whatever collections the
# playbook needs; this only runs it.
#
# payload-dir, if given, is copied to /tmp/payload in the guest before the
# script runs.  Fetching on the host rather than in the guest keeps proxy and
# CA handling in one place and puts the download in the build log.
#
# VM_VCPUS and VM_VMEM size the boot, and build-vm exports the same values it
# gave gen-vm.  They affect how fast the probe runs, never what it observes.
#
# The disk is attached with discard=unmap so an "fstrim" inside the guest
# reaches the qcow2 rather than stopping at the guest filesystem.  Only a trim
# boot asks for it, and it costs the other flavours nothing: without a discard
# the option changes no behaviour at all.
#

set -eu

IMAGE=$1
GUEST_USER=$2
SCRIPT=$3
PAYLOAD="${4:-}"

PERSIST="${PROBE_PERSIST:-0}"
ANSIBLE="${PROBE_ANSIBLE:-0}"
PORT="${PROBE_SSH_PORT:-2222}"
BOOT_TIMEOUT="${PROBE_BOOT_TIMEOUT:-300}"
# Matched to the gen-vm boot rather than fixed here, so one knob sizes every
# build-time boot.  The defaults stand alone: probe-guest is runnable by hand
# against any qcow2, not only from build-vm.
VCPUS="${VM_VCPUS:-4}"
VMEM="${VM_VMEM:-4096}"
QEMU="${QEMU_PATH:-/opt/qemu/bin/}qemu-system-x86_64"
OVERLAY=/tmp/probe-overlay.qcow2
SERIAL=/tmp/probe-serial.log
PIDFILE=/tmp/probe-qemu.pid

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o LogLevel=ERROR -o ConnectTimeout=5 -i /root/.ssh/id_rsa -p ${PORT}"
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o LogLevel=ERROR -o ConnectTimeout=5 -i /root/.ssh/id_rsa -P ${PORT}"

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    fi
    rm -f "${OVERLAY}" "${PIDFILE}"
}
trap cleanup EXIT

rm -f "${OVERLAY}"
if [ "${PERSIST}" = "1" ]; then
    DISK="${IMAGE}"
    echo "probe-guest: PROBE_PERSIST=1, changes will be kept" >&2
else
    DISK="${OVERLAY}"
    /opt/qemu/bin/qemu-img create -q -f qcow2 -F qcow2 -b "${IMAGE}" \
        "${OVERLAY}"
fi

echo "probe-guest: booting ${IMAGE}" >&2
"${QEMU}" \
    -machine q35,accel=kvm \
    -cpu host \
    -m "${VMEM}" \
    -smp "${VCPUS}" \
    -drive "if=virtio,format=qcow2,file=${DISK},discard=unmap,detect-zeroes=unmap" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${PORT}-:22" \
    -device virtio-net-pci,netdev=n0 \
    -display none \
    -serial "file:${SERIAL}" \
    -daemonize \
    -pidfile "${PIDFILE}"

waited=0
# shellcheck disable=SC2086
until ssh ${SSH_OPTS} "${GUEST_USER}@127.0.0.1" true 2>/dev/null; do
    waited=$((waited + 5))
    if [ "${waited}" -ge "${BOOT_TIMEOUT}" ]; then
        echo "probe-guest: guest did not answer SSH within ${BOOT_TIMEOUT}s" >&2
        echo "--- serial console ---" >&2
        tail -n 100 "${SERIAL}" >&2 || true
        exit 1
    fi
    sleep 5
done
echo "probe-guest: SSH up after ${waited}s" >&2

if [ -n "${PAYLOAD}" ]; then
    echo "probe-guest: copying ${PAYLOAD} to /tmp/payload in the guest" >&2
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${GUEST_USER}@127.0.0.1" 'rm -rf /tmp/payload'
    # shellcheck disable=SC2086
    scp ${SCP_OPTS} -r "${PAYLOAD}" "${GUEST_USER}@127.0.0.1:/tmp/payload"
fi

status=0
if [ "${ANSIBLE}" = "1" ]; then
    # 127.0.0.1 and a forwarded port, not the guest's own address: the guest
    # is behind SLIRP and has no address reachable from here.  The same key
    # and the same host-key handling the SSH path above uses, because it is
    # the same connection -- ansible just drives it.
    #
    # ANSIBLE_HOST_KEY_CHECKING is off for the reason StrictHostKeyChecking is
    # off above: every probe boot is a new guest on the same port, so a known
    # host is a stale one.
    # The host is named, and ansible_host carries the address.  Writing
    # "127.0.0.1" as the inventory host name instead looks equivalent and is
    # not: ansible resolves "localhost" to an inventory host called 127.0.0.1
    # when one exists, so every "delegate_to: localhost" task in a playbook
    # inherits this host's ansible_port and ansible_user and runs *inside the
    # guest* over the forwarded port.
    #
    # That is not a theoretical hazard.  It silently moved a role's entire
    # controller-side half -- a git clone, a patch series, a tarball -- into
    # the guest, where each step succeeded, and surfaced two tasks later as
    # "Could not find or access /tmp/.../v7.2.4.tar.gz on the Ansible
    # Controller" with nothing pointing at the inventory.  A role that fetches
    # on the controller precisely because the guest's network is not to be
    # depended on would quietly be doing the opposite.
    #
    # localhost is deliberately NOT given a line of its own here: that would
    # make it a real inventory host, and a playbook with "hosts: all" would
    # then run against the builder as well as the guest.  With no match,
    # ansible's implicit localhost is used, which is connection=local.
    INVENTORY=/tmp/probe-inventory.ini
    cat > "${INVENTORY}" <<EOF
[guest]
probe-guest ansible_host=127.0.0.1 ansible_port=${PORT} ansible_user=${GUEST_USER} ansible_ssh_private_key_file=/root/.ssh/id_rsa ansible_python_interpreter=/usr/bin/python3
EOF
    echo "probe-guest: running playbook ${SCRIPT}" >&2
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    ANSIBLE_FORCE_COLOR=0 \
        ansible-playbook -i "${INVENTORY}" "${SCRIPT}" || status=$?
    rm -f "${INVENTORY}"
else
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${GUEST_USER}@127.0.0.1" 'bash -s' < "${SCRIPT}" || status=$?
fi

# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${GUEST_USER}@127.0.0.1" 'sudo -n poweroff' 2>/dev/null || true
waited=0
while [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; do
    waited=$((waited + 2))
    [ "${waited}" -ge 60 ] && break
    sleep 2
done

if [ "${status}" -ne 0 ]; then
    if [ "${ANSIBLE}" = "1" ]; then
        echo "probe-guest: playbook failed with status ${status}" >&2
    else
        echo "probe-guest: script failed with status ${status}" >&2
    fi
fi
exit "${status}"
