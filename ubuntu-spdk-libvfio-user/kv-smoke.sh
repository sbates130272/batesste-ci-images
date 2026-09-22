#!/bin/bash
#
# kv-smoke.sh
#
# Drive a KV Store / Retrieve / Exist / Delete / List round trip against a
# running target over vfio-user, from inside the container, with no guest and
# no QEMU in the way.
#
# This is the answer to "the guest says KV I/O fails" -- it splits the question
# in two. If this passes, the target, the kvdev and the KV command set are all
# fine and the fault is above the socket: the wrong NSID (KV Store is opcode
# 0x01, the same number as block Write, so a KV command sent to an LBA
# namespace is executed as a block write rather than rejected -- see README.md),
# the wrong controller, or a guest that never enumerated the namespace. If it
# fails, the fault is at or below the socket and the output names the phase.
#
# Usage:
#   kv-smoke [socket-dir]     defaults to ${VFIO_USER_SOCKET_DIR}
#
# The work is done by the fork's own test/nvmf/kv/kv_host, installed as
# kv-host: using the fork's initiator rather than one written here means the
# check moves with the fork's own idea of the command set.
#

set -euo pipefail

SOCKET_DIR=${1:-${VFIO_USER_SOCKET_DIR:-/tmp/vfio-sockets/nvme}}
KV_HOST=${KV_HOST:-/usr/local/bin/kv-host}
KV_SMOKE_MEM_SIZE=${KV_SMOKE_MEM_SIZE:-256}

log() { echo "[kv-smoke] $*" >&2; }
die() { echo "[kv-smoke] ERROR: $*" >&2; exit 1; }

[ -x "${KV_HOST}" ] || die "kv-host not found at ${KV_HOST}"
[ -S "${SOCKET_DIR}/cntrl" ] || die "no vfio-user socket at ${SOCKET_DIR}/cntrl -- is the target running?"

# Same fallback the entrypoint makes for the target: a container gets no
# hugepages unless it is privileged or /dev/hugepages is mounted with pages
# reserved, and kv_host takes no EAL arguments of its own (see
# kv-host-no-huge.patch).
nr=0
[ -r /proc/sys/vm/nr_hugepages ] && nr=$(cat /proc/sys/vm/nr_hugepages)
if [ -d /dev/hugepages ] && [ -w /dev/hugepages ] && [ "${nr}" -gt 0 ]; then
    log "hugepages: ${nr} available, using them"
else
    log "hugepages: none available, falling back to --no-huge -s ${KV_SMOKE_MEM_SIZE}"
    export KV_HOST_NO_HUGE=1
    export KV_HOST_MEM_SIZE="${KV_SMOKE_MEM_SIZE}"
fi

# Both of these are worth saying out loud rather than leaving to be discovered:
# libvfio-user serves one client at a time, so this cannot be run against a
# socket a guest already holds, and the round trip leaves its own keys behind
# in whichever KV namespace it found.
log "attaching to ${SOCKET_DIR}/cntrl (no guest may be attached to it)"
log "this writes test keys into the first KV namespace it finds"

# `reject` and not `allow`: the image sets no KV Exec allowlist, so default-deny
# is the behaviour to assert. `allow` would need the allowlist RPCs called first
# and would fail here for a reason that has nothing to do with the data path.
"${KV_HOST}" "${SOCKET_DIR}" reject

log "PASS: KV round trip completed over ${SOCKET_DIR}/cntrl"
