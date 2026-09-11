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
# payload-dir, if given, is copied to /tmp/payload in the guest before the
# script runs.  Fetching on the host rather than in the guest keeps proxy and
# CA handling in one place and puts the download in the build log.
#
# VM_VCPUS and VM_VMEM size the boot, and build-vm exports the same values it
# gave gen-vm.  They affect how fast the probe runs, never what it observes.
#

set -eu

IMAGE=$1
GUEST_USER=$2
SCRIPT=$3
PAYLOAD="${4:-}"

PERSIST="${PROBE_PERSIST:-0}"
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
    -drive "if=virtio,format=qcow2,file=${DISK}" \
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
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${GUEST_USER}@127.0.0.1" 'bash -s' < "${SCRIPT}" || status=$?

# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${GUEST_USER}@127.0.0.1" 'sudo -n poweroff' 2>/dev/null || true
waited=0
while [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; do
    waited=$((waited + 2))
    [ "${waited}" -ge 60 ] && break
    sleep 2
done

if [ "${status}" -ne 0 ]; then
    echo "probe-guest: script failed with status ${status}" >&2
fi
exit "${status}"
