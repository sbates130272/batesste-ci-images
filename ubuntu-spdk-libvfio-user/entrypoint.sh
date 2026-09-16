#!/bin/bash
#
# entrypoint.sh
#
# Start SPDK's NVMe-oF target, build one NVMe controller out of NVME_NAMESPACES
# and serve it on a vfio-user socket at ${VFIO_USER_SOCKET_DIR}/cntrl. The
# container's lifetime is the controller's lifetime: the guest sees a surprise
# removal if this exits.
#
# Usage:
#   entrypoint.sh            serve until killed (the default)
#   entrypoint.sh --probe    configure, assert the socket appeared, tear down
#   entrypoint.sh <cmd> ...  run something else in this image (rpc.py, bash)
#

set -euo pipefail

SPDK_DIR=${SPDK_DIR:-/opt/spdk}
NVME_NAMESPACES=${NVME_NAMESPACES:-lba:malloc:512M,kv:mem}
NQN=${NQN:-nqn.2019-07.io.spdk:cnode1}
VFIO_USER_SOCKET_DIR=${VFIO_USER_SOCKET_DIR:-/tmp/vfio-sockets/nvme}
SPDK_SERIAL=${SPDK_SERIAL:-SPDKVFU01}
SPDK_CPUMASK=${SPDK_CPUMASK:-0x1}
SPDK_HUGE=${SPDK_HUGE:-auto}
SPDK_MEM_SIZE=${SPDK_MEM_SIZE:-1024}
SPDK_RPC_SOCK=${SPDK_RPC_SOCK:-/var/tmp/spdk.sock}
# nvmf_create_transport tuning. The defaults are SPDK's own vfio-user example
# values, which are what PR #183's working stack uses.
SPDK_QUEUE_DEPTH=${SPDK_QUEUE_DEPTH:-1024}
SPDK_MAX_QPAIRS=${SPDK_MAX_QPAIRS:-16}

# Both on stderr: huge_args() below returns its flags on stdout, and a log line
# landing there would be parsed as an argument to nvmf_tgt.
log() { echo "[spdk-vfu] $*" >&2; }
die() { echo "[spdk-vfu] ERROR: $*" >&2; exit 1; }

rpc() { python3 "${SPDK_DIR}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" "$@"; }

PROBE=0
case "${1:-}" in
    --probe) PROBE=1; shift ;;
    "")      ;;
    # Anything else is a command to run in this image instead of the target.
    *)       exec "$@" ;;
esac

if ! [ -x "${SPDK_DIR}/build/bin/nvmf_tgt" ]; then
    die "nvmf_tgt not found under ${SPDK_DIR}/build/bin"
fi

# A caller who brings their own SPDK JSON config wants all of the below skipped:
# the config already names its transports, bdevs, kvdevs, subsystems and
# listeners, and generating a second set on top of it would only conflict.
if [ -n "${SPDK_JSON_CONFIG:-}" ]; then
    [ -f "${SPDK_JSON_CONFIG}" ] || die "SPDK_JSON_CONFIG=${SPDK_JSON_CONFIG} not found"
    log "starting nvmf_tgt from ${SPDK_JSON_CONFIG} (NVME_NAMESPACES ignored)"
    exec "${SPDK_DIR}/build/bin/nvmf_tgt" \
        -r "${SPDK_RPC_SOCK}" -m "${SPDK_CPUMASK}" \
        --json "${SPDK_JSON_CONFIG}"
fi

# Size in MiB from a 512M / 2G / bare-MiB spelling. Used for bdev_malloc_create,
# whose total_size argument is already in MB, and scaled to bytes where a file
# has to be created.
to_mib() {
    local spec=$1 num unit
    num=${spec%[KkMmGg]}
    unit=${spec#"${num}"}
    case "${unit}" in
        K|k) echo $(((num + 1023) / 1024)) ;;
        M|m|"") echo "${num}" ;;
        G|g) echo $((num * 1024)) ;;
        *) die "unrecognised size '${spec}'" ;;
    esac
}

# Hugepages are the normal SPDK memory source, but a container gets none unless
# it is privileged or /dev/hugepages is mounted with pages already reserved.
# Falling back to --no-huge keeps the common `docker run` case working; the
# device still reaches guest RAM, which arrives as an mmap-able descriptor over
# the vfio-user socket rather than from SPDK's own pool.
huge_args() {
    local nr=0
    [ -r /proc/sys/vm/nr_hugepages ] && nr=$(cat /proc/sys/vm/nr_hugepages)
    case "${SPDK_HUGE}" in
        on)
            log "hugepages: forced on"
            ;;
        off)
            log "hugepages: forced off (--no-huge -s ${SPDK_MEM_SIZE})"
            printf -- '--no-huge\n-s\n%s\n' "${SPDK_MEM_SIZE}"
            ;;
        auto)
            if [ -d /dev/hugepages ] && [ -w /dev/hugepages ] && [ "${nr}" -gt 0 ]; then
                log "hugepages: ${nr} available, using them"
            else
                log "hugepages: none available, falling back to --no-huge -s ${SPDK_MEM_SIZE}"
                printf -- '--no-huge\n-s\n%s\n' "${SPDK_MEM_SIZE}"
            fi
            ;;
        *)
            die "SPDK_HUGE must be auto, on or off (got '${SPDK_HUGE}')"
            ;;
    esac
}

HUGE_ARGS=()
while IFS= read -r arg; do
    [ -n "${arg}" ] && HUGE_ARGS+=("${arg}")
done < <(huge_args)

log "namespaces: ${NVME_NAMESPACES}"
log "nqn:        ${NQN}"
log "socket:     ${VFIO_USER_SOCKET_DIR}/cntrl"

mkdir -p "${VFIO_USER_SOCKET_DIR}"
# libvfio-user unlinks its socket on a clean teardown, but a container killed
# with SIGKILL leaves one behind and the listener then refuses to bind.
rm -f "${VFIO_USER_SOCKET_DIR}/cntrl" "${SPDK_RPC_SOCK}" "${SPDK_RPC_SOCK}.lock"

"${SPDK_DIR}/build/bin/nvmf_tgt" \
    -r "${SPDK_RPC_SOCK}" \
    -m "${SPDK_CPUMASK}" \
    ${HUGE_ARGS[@]+"${HUGE_ARGS[@]}"} &
TGT_PID=$!

# Forward a container stop to the target so libvfio-user tears the socket down
# rather than leaving a stale one in a shared volume.
trap 'kill -TERM "${TGT_PID}" 2>/dev/null || true' TERM INT

for _ in $(seq 1 120); do
    if [ -S "${SPDK_RPC_SOCK}" ] && rpc rpc_get_methods >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${TGT_PID}" 2>/dev/null; then
        die "nvmf_tgt exited during startup"
    fi
    sleep 0.25
done
rpc rpc_get_methods >/dev/null 2>&1 || die "nvmf_tgt never answered on ${SPDK_RPC_SOCK}"

rpc nvmf_create_transport -t VFIOUSER \
    -q "${SPDK_QUEUE_DEPTH}" -m "${SPDK_MAX_QPAIRS}"
rpc nvmf_create_subsystem "${NQN}" -s "${SPDK_SERIAL}" -a

lba_count=0
kv_count=0
IFS=',' read -r -a ns_specs <<< "${NVME_NAMESPACES}"
for spec in "${ns_specs[@]}"; do
    [ -n "${spec}" ] || continue
    IFS=':' read -r kind backing a1 a2 <<< "${spec}"
    case "${kind}:${backing}" in
        lba:malloc)
            # lba:malloc:<size>[:<blocklen>]
            [ -n "${a1:-}" ] || die "lba:malloc needs a size (e.g. lba:malloc:512M)"
            name="Malloc${lba_count}"
            rpc bdev_malloc_create -b "${name}" \
                "$(to_mib "${a1}")" "${a2:-4096}"
            rpc nvmf_subsystem_add_ns "${NQN}" "${name}"
            lba_count=$((lba_count + 1))
            log "LBA namespace ${name}: ${a1} of memory, ${a2:-4096}B blocks"
            ;;
        lba:aio)
            # lba:aio:<path>[:<blocklen>[:<size>]] -- the file is created sparsely
            # when absent, so a caller can bind-mount an empty directory.
            [ -n "${a1:-}" ] || die "lba:aio needs a path (e.g. lba:aio:/data/ns.img)"
            name="Aio${lba_count}"
            if [ ! -e "${a1}" ]; then
                size_mib=$(to_mib "${SPDK_AIO_DEFAULT_SIZE:-1G}")
                log "creating ${a1} (${size_mib}MiB, sparse)"
                truncate -s "${size_mib}M" "${a1}"
            fi
            rpc bdev_aio_create "${a1}" "${name}" "${a2:-4096}"
            rpc nvmf_subsystem_add_ns "${NQN}" "${name}"
            lba_count=$((lba_count + 1))
            log "LBA namespace ${name}: file ${a1}, ${a2:-4096}B blocks"
            ;;
        kv:mem)
            # kv:mem[:<max_value_len>[:<max_num_keys>]]
            name="KvMem${kv_count}"
            kv_args=()
            [ -n "${a1:-}" ] && kv_args+=(--max-value-len "${a1}")
            [ -n "${a2:-}" ] && kv_args+=(--max-num-keys "${a2}")
            rpc kvdev_mem_create "${name}" ${kv_args[@]+"${kv_args[@]}"}
            rpc nvmf_subsystem_add_kv_ns "${NQN}" "${name}"
            kv_count=$((kv_count + 1))
            log "KV namespace ${name}: memory backed"
            ;;
        kv:*)
            # kvdev_rados is the only other backend the fork has, and it needs a
            # Ceph cluster this image deliberately cannot reach -- see README.md.
            die "unsupported KV backing '${backing}': this image builds without --with-rbd, so kv:mem is the only KV namespace it can serve"
            ;;
        *)
            die "unrecognised namespace spec '${spec}'"
            ;;
    esac
done

rpc nvmf_subsystem_add_listener "${NQN}" \
    -t VFIOUSER -a "${VFIO_USER_SOCKET_DIR}" -s 0

for _ in $(seq 1 80); do
    [ -S "${VFIO_USER_SOCKET_DIR}/cntrl" ] && break
    sleep 0.25
done
[ -S "${VFIO_USER_SOCKET_DIR}/cntrl" ] || die "vfio-user socket never appeared"

log "serving ${lba_count} LBA + ${kv_count} KV namespace(s) on ${VFIO_USER_SOCKET_DIR}/cntrl"

if [ "${PROBE}" -eq 1 ]; then
    # Assert the target agrees with what we asked for, rather than trusting that
    # the RPCs returned success: a fork whose add_kv_ns silently no-ops would
    # otherwise pass.
    rpc nvmf_get_subsystems | python3 -c '
import json, sys
want_lba, want_kv = int(sys.argv[1]), int(sys.argv[2])
nqn = sys.argv[3]
subs = [s for s in json.load(sys.stdin) if s.get("nqn") == nqn]
if not subs:
    sys.exit(f"subsystem {nqn} not found")
namespaces = subs[0].get("namespaces", [])
kv = [n for n in namespaces if "kvdev_name" in n]
lba = [n for n in namespaces if "kvdev_name" not in n]
print(f"[spdk-vfu] target reports {len(lba)} LBA + {len(kv)} KV namespace(s)")
if len(lba) != want_lba or len(kv) != want_kv:
    sys.exit(f"expected {want_lba} LBA + {want_kv} KV, got {len(lba)} + {len(kv)}")
' "${lba_count}" "${kv_count}" "${NQN}"
    log "probe OK"
    kill -TERM "${TGT_PID}" 2>/dev/null || true
    wait "${TGT_PID}" 2>/dev/null || true
    exit 0
fi

wait "${TGT_PID}"
