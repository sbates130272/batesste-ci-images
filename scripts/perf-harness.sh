#!/usr/bin/env bash
#
# perf-harness.sh
#
# Boot the qualification stacks this repo's images make possible, and measure
# them. Writes a summary.json that scripts/publish-perf.py turns into the
# trend page and the README shields.
#
#   scripts/perf-harness.sh --out output/perf
#
# Images come from the environment, and are expected to be pinned tags:
# QEMU_IMAGE, ERNIC_IMAGE, ROCJITSU_IMAGE, QCOW2_IMAGE, QCOW2_IONIC_IMAGE.
#
# WHY THIS EXISTS
#   ubuntu-qcow2-gen's flavours cannot be end-to-end tested in their own
#   builds: the probe boot has no vfio-user device, so checks/rocjitsu.sh can
#   assert that the right driver is installed for the booted kernel and
#   nothing about whether the emulated GPU comes up. The "Open" section of
#   consumers/rocm-xio-rocjitsu.md names the qualification that was missing --
#   amdgpu bound under /sys/bus/pci/drivers/amdgpu/, a KFD node present, no
#   vcn/jpeg failure. This runs it, and then measures what it qualified.
#
# TWO PHASES
#   Each vfio-user device wants a guest built for it, and no one qcow2 flavour
#   carries both, so the stack comes up twice:
#
#     rocjitsu   ubuntu-qcow2-gen@rocjitsu against the rocjitsu server, with
#                an emulated NVMe namespace.
#     ernic      ubuntu-qcow2-gen@ionic against the ernic server running its
#                s3 backend.
#
#   An earlier version of this file booted one guest against both sockets, and
#   said so in a long apology: the ernic figure was a count of sized BARs,
#   because the rocjitsu guest has no RDMA driver and the device enumerated
#   into nothing. Two boots is what it costs to have a real number instead.
#
# WHAT IS MEASURED
#   gemm      GFLOP/s of a validated FP32 GEMM on the emulated gfx1250.
#   nvme      GB/s of sequential reads from the emulated NVMe controller,
#             through libaio into host memory and through hipFile into GPU
#             memory, both against files on one filesystem in one boot so the
#             two can be read as a ratio.
#   ernic     GB/s of 1 MiB object GETs over RDMA from the emulator's own
#             object store -- the loopback deployment, where one guest and one
#             server are a complete object fabric with no peer and no TAP.
#   boot      Seconds from "compose up" to the rocjitsu guest accepting SSH.
#
#   None of these are hardware numbers and none should be read as one. This is
#   an instruction-level GPU model, QEMU's NVMe model and a software RDMA NIC;
#   what moves in the trend is the cost of the emulation and of the driver and
#   library paths above it, which is exactly the thing a change in this repo
#   can break.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPOSE_FILE="${REPO_ROOT}/compose/perf-stack.yml"

OUT="${REPO_ROOT}/output/perf"
KEEP_UP=0

VM_IMAGES_ROOT="${VM_IMAGES_DIR:-/var/lib/qemu-tool/images}"
VM_VCPUS="${VM_VCPUS:-4}"
VM_VMEM="${VM_VMEM:-8192}"
VM_SHM_SIZE="${VM_SHM_SIZE:-12g}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_NVME_COUNT="${VM_NVME_COUNT:-1}"
ROCJITSU_CONFIG="${ROCJITSU_CONFIG:-gfx1250_mi455x.json}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
# Dispatches are interpreted one instruction at a time, so a GEMM iteration is
# seconds. Eight is enough to average out host scheduling without making the
# job's wall clock the reason nobody runs it.
GEMM_ITERS="${GEMM_ITERS:-8}"
# Passes of the 32 MiB payload through hipFile. Fewer than the GEMM's, because
# each pass is 32 reads through an emulated controller rather than one kernel.
HIPFILE_ITERS="${HIPFILE_ITERS:-4}"

# The s3 backend's own geometry, matching rocm-ernic's s3 lane so the two
# repositories' numbers describe the same deployment. The endpoint address has
# to sit on the subnet the guest addresses the emulated NIC from -- the
# emulator terminates the HTTP control plane in-band on the NIC itself, so
# there is no host network path and nothing routes between them.
S3_SIZE="${S3_SIZE:-256M}"
S3_BUCKET="${S3_BUCKET:-ernic}"
S3_ADDR="${S3_ADDR:-192.168.200.1}"
S3_PORT="${S3_PORT:-9000}"
S3_GUEST_ADDR="${S3_GUEST_ADDR:-192.168.200.10}"
S3_GUEST_PREFIX="${S3_GUEST_PREFIX:-24}"
S3_BUFFER="${S3_BUFFER:-8388608}"
S3_ITERS="${S3_ITERS:-10}"
# The tracked object size, and the one the shield speaks for. 1 MiB is also
# the block size gemm-hipfile-bench.hip reads in, so the two storage numbers
# on the trend page are at the same granularity.
S3_OBJECT_BYTES="${S3_OBJECT_BYTES:-1048576}"

# The ionic emulated NIC's PCI identity. Matched on rather than any device
# name: the name is rewritten twice on the way up by udev, and any list of
# name patterns is a snapshot of one moment in that sequence.
ERNIC_PCI_VENDOR=1dd8
ERNIC_PCI_DEVICE=100a

usage() {
    cat <<'EOF'
usage: perf-harness.sh [--out DIR] [--keep-up] [-h]

  --out DIR   where summary.json and the logs are written
              (default: output/perf)
  --keep-up   leave the last phase's compose stack running, for poking at the
              guest by hand. The default tears it down even on failure.

Required in the environment (pinned tags, never :latest):
  QEMU_IMAGE  ERNIC_IMAGE  ROCJITSU_IMAGE  QCOW2_IMAGE  QCOW2_IONIC_IMAGE
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift 2 ;;
        --keep-up) KEEP_UP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "perf-harness.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

log()  { printf '=== %s\n' "$*"; }
fail() { echo "perf-harness.sh: $*" >&2; exit 1; }

for var in QEMU_IMAGE ERNIC_IMAGE ROCJITSU_IMAGE QCOW2_IMAGE QCOW2_IONIC_IMAGE; do
    [ -n "${!var:-}" ] || fail "${var} must be set to a pinned image tag"
done

mkdir -p "${OUT}"
# Absolute from here on. OUT is handed to `docker run -v` as a bind-mount
# source, and Docker reads a relative source containing a slash as an invalid
# volume name rather than as a path -- so `--out output/perf`, which is what
# the workflow passes, would fail the firmware staging step and take the whole
# phase with it.
OUT=$(cd "${OUT}" && pwd)
METRICS="${OUT}/metrics.jsonl"
: > "${METRICS}"

# One line per measurement, assembled into summary.json at the end. A metric
# that could not be taken is recorded with a reason rather than dropped: a
# gap in the history that says why is worth more than a missing point that
# looks like the lane never ran.
record_metric() {
    python3 - "$METRICS" "$@" <<'PY'
import json, sys
path, key, status, unit = sys.argv[1:5]
value = sys.argv[5]
note = sys.argv[6] if len(sys.argv) > 6 else ""
rec = {"key": key, "status": status, "unit": unit, "note": note}
rec["value"] = float(value) if status == "ok" and value else None
with open(path, "a") as fh:
    fh.write(json.dumps(rec) + "\n")
print(f"metric {key}: {status} {rec['value']} {unit} {note}".rstrip())
PY
}

compose() { docker compose -f "${COMPOSE_FILE}" --project-directory "${OUT}" "$@"; }

PHASE=""

write_summary() {
    log "writing ${OUT}/summary.json"
    python3 - "${METRICS}" "${OUT}/summary.json" <<'PY'
import json, os, sys, datetime
metrics = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
summary = {
    "schema_version": 1,
    "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "meta": {
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "sha": os.environ.get("GITHUB_SHA", ""),
        "runner": os.environ.get("PERF_RUNNER_CLASS", "github-hosted"),
        "images": {
            k.lower(): os.environ.get(k, "")
            for k in ("QEMU_IMAGE", "ERNIC_IMAGE", "ROCJITSU_IMAGE",
                      "QCOW2_IMAGE", "QCOW2_IONIC_IMAGE")
        },
    },
    "metrics": {m.pop("key"): m for m in metrics},
}
json.dump(summary, open(sys.argv[2], "w"), indent=2)
json.dump(summary, sys.stdout, indent=2)
print()
PY
}

# Collect what this phase produced and take it down. Never allowed to fail the
# run: by this point the phase's measurements are already in metrics.jsonl,
# and losing them to a docker error would be the worst possible trade.
phase_down() {
    [ -n "${PHASE}" ] || return 0
    compose logs --no-color > "${OUT}/compose-${PHASE}.log" 2>&1 || true
    compose down --volumes --remove-orphans > /dev/null 2>&1 || true
    PHASE=""
}

# Written from the exit path rather than the end of the script on purpose: a
# phase that fails hard still leaves behind every number measured before it,
# which is what makes the uploaded artifact worth reading. Publishing is gated
# on the whole run succeeding, so a partial summary informs without trending.
teardown() {
    local rc=$?
    write_summary || true
    if [ "${KEEP_UP}" -eq 1 ]; then
        log "leaving the stack up (--keep-up); ssh -p ${VM_SSH_PORT} ${SSH_USER:-}@localhost"
        return "$rc"
    fi
    log "collecting logs and tearing down"
    phase_down
    return "$rc"
}

# ── preflight ──────────────────────────────────────────

log "preflight"
command -v docker > /dev/null || fail "docker is not on PATH"
docker compose version > /dev/null 2>&1 || fail "docker compose v2 is required"

# KVM is not optional here. Under TCG the ROCm dispatch path runs for hours
# and, worse, the numbers would be recorded as a baseline measured under
# software emulation of software emulation -- which poisons the trend for
# every run after it. Refuse rather than produce that.
[ -c /dev/kvm ] || fail "/dev/kvm is not present; this stack requires KVM"
[ -w /dev/kvm ] || fail "/dev/kvm is not writable by $(id -un); see the udev rule in the workflow"

sudo -n mkdir -p "${VM_IMAGES_ROOT}"
sudo -n chmod 777 "${VM_IMAGES_ROOT}"

# ── per-phase plumbing ─────────────────────────────────

SSH_USER=""
SSH_KEY=""
VM_NAME=""
VM_IMAGES_DIR=""
SSH_OPTS=()

guest()    { ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "$@"; }
guest_sh() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'bash -s'; }
to_guest() { scp -q "${SSH_OPTS[@]/-p/-P}" "$1" "${SSH_USER}@localhost:$2"; }
from_guest() { scp -q "${SSH_OPTS[@]/-p/-P}" "${SSH_USER}@localhost:$1" "$2"; }

# Same as guest_sh, with NAME=VALUE arguments exported ahead of the script.
#
# Setting them on the ssh command line does not work and does not complain:
# ssh forwards no environment unless the server's AcceptEnv says so, so the
# remote script sees them unset and quietly takes whatever default it wrote.
# Putting the assignments in the stream is the version that actually arrives.
guest_env_sh() {
    {
        local kv
        for kv in "$@"; do
            printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"
        done
        cat
    } | ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'bash -s'
}

# ubuntu-qcow2-gen publishes FROM scratch with nothing but /output, so there
# is no command to run -- the container exists only to copy out of.
extract_payload() {
    local image=$1 dir=$2
    log "extracting the guest payload from ${image}"
    # sudo, because qemu-tool runs as root in its container and leaves the
    # previous phase's disk owned by it.
    sudo -n rm -rf "${dir}"
    mkdir -p "${dir}"
    local cid
    cid=$(docker create "${image}")
    docker cp "${cid}:/output/." "${dir}"
    docker rm -f "${cid}" > /dev/null

    local info="${dir}/vm-info.json"
    [ -f "${info}" ] || fail "no vm-info.json in the payload from ${image}"
    VM_IMAGES_DIR="${dir}"
    VM_NAME=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["vm_name"])' "${info}")
    SSH_USER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["username"])' "${info}")
    SSH_KEY="${dir}/id_rsa"
    chmod 600 "${SSH_KEY}"
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("release",d["release"],"kernel",d["kernel_release"],"flavour",d.get("flavour",""))' "${info}"
    log "guest ${VM_NAME}, user ${SSH_USER}"

    # ConnectTimeout bounds the TCP handshake; ServerAlive* bounds an
    # established session that stops answering, which is what a guest that
    # wedges mid-measurement looks like from here. Neither bounds the banner
    # exchange -- see wait_for_ssh, which needs its own hard kill.
    SSH_OPTS=(-i "${SSH_KEY}" -p "${VM_SSH_PORT}"
              -o BatchMode=yes
              -o NoHostAuthenticationForLocalhost=yes
              -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null
              -o ConnectTimeout=10
              -o ServerAliveInterval=15
              -o ServerAliveCountMax=4
              -o LogLevel=ERROR)
}

# The .env compose reads. Rewritten between phases: which guest boots, which
# backend the ernic server serves and how many NVMe namespaces exist are all
# phase decisions.
write_env() {
    cat > "${OUT}/.env" <<EOF
QEMU_IMAGE=${QEMU_IMAGE}
ERNIC_IMAGE=${ERNIC_IMAGE}
ROCJITSU_IMAGE=${ROCJITSU_IMAGE}
ROCJITSU_CONFIG=${ROCJITSU_CONFIG}
ERNIC_BACKEND=${ERNIC_BACKEND:-loopback}
VM_IMAGES_DIR=${VM_IMAGES_DIR}
VM_NAME=${VM_NAME}
VM_VCPUS=${VM_VCPUS}
VM_VMEM=${VM_VMEM}
VM_SHM_SIZE=${VM_SHM_SIZE}
VM_SSH_PORT=${VM_SSH_PORT}
VM_NVME_COUNT=${VM_NVME_COUNT}
EOF
}

# Start one vfio-user server and wait for its socket. Started by name rather
# than through depends_on, because which server this phase wants is not a
# property of the compose file.
start_server() {
    local service=$1 health=""
    log "starting the ${service} vfio-user server"
    compose up --detach "${service}"
    for _ in $(seq 1 45); do
        health=$(compose ps --format json "${service}" 2>/dev/null \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Health",""))' \
            2>/dev/null || true)
        [ "${health}" = healthy ] && break
        sleep 2
    done
    [ "${health}" = healthy ] || {
        compose logs --no-color "${service}"
        fail "${service} never became healthy"
    }
    log "${service} healthy"
}

# Returns the seconds from "up" to SSH, through the global. Not a metric on
# its own for every phase -- only the rocjitsu guest's boot is trended, so the
# series keeps one meaning.
BOOT_SECONDS=0
start_guest() {
    log "starting the guest"
    compose up --detach qemu
    log "waiting for guest SSH (up to ${BOOT_TIMEOUT}s)"
    local start elapsed=0
    start=$(date +%s)
    # `timeout`, not `guest`, and the difference is load-bearing. QEMU's slirp
    # hostfwd accepts the connection on VM_SSH_PORT the moment the container
    # starts, before a guest kernel exists -- so a guest that wedges after the
    # port is forwarded but before sshd sends its banner leaves ssh blocked in
    # the version exchange, which no ssh timeout option covers. The loop would
    # then never recompute `elapsed`, BOOT_TIMEOUT would never fire, and the
    # job would hang to the workflow's 150-minute wall without ever reaching
    # the `compose logs` dump below. An amdgpu probe deadlock on the emulated
    # gfx1250 is exactly that shape: the failure this lane exists to catch is
    # the one that would otherwise silence it.
    until timeout 20 ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" true 2>/dev/null; do
        elapsed=$(( $(date +%s) - start ))
        [ "${elapsed}" -lt "${BOOT_TIMEOUT}" ] || {
            compose logs --no-color qemu
            fail "guest did not accept SSH within ${BOOT_TIMEOUT}s"
        }
        sleep 5
    done
    BOOT_SECONDS=$(( $(date +%s) - start ))
    log "guest up after ${BOOT_SECONDS}s"
}

trap teardown EXIT

# ══ phase 1: rocjitsu ══════════════════════════════════

phase_rocjitsu() {
    PHASE=rocjitsu
    log "PHASE rocjitsu"
    extract_payload "${QCOW2_IMAGE}" "${VM_IMAGES_ROOT}/rocjitsu"
    write_env
    start_server rocjitsu
    start_guest
    record_metric boot_seconds ok s "${BOOT_SECONDS}" "SSH-ready, KVM, ${VM_VCPUS} vCPU"

    log "checking the emulated devices enumerated"
    guest_sh > "${OUT}/lspci-rocjitsu.txt" <<'GUEST'
set -euo pipefail
lspci -nn
GUEST
    cat "${OUT}/lspci-rocjitsu.txt"
    guest 'lspci -d ::0108 | grep -q .' || fail "no NVMe controller in the guest"
    guest 'lspci -d 1002: | grep -q .' || fail "no AMD vfio-user device in the guest"

    # ── bind amdgpu to the rocjitsu device ─────────────
    #
    # The guest blacklists amdgpu on purpose -- neither the device nor its
    # firmware exists until a vfio-user server is serving, and an autoloaded
    # copy wedges the guest. So the two firmware files the guest deliberately
    # does not carry get staged now, from the same rocjitsu image serving the
    # device, and then the module is loaded by hand.

    log "generating the guest firmware gap from ${ROCJITSU_IMAGE}"
    local fw_dir="${OUT}/fw"
    rm -rf "${fw_dir}"; mkdir -p "${fw_dir}"
    # --set gap (the default) emits gc_12_1_0_imu.bin, ip_discovery.bin and
    # the uni_mes aliases, and nothing that would overwrite the packaged
    # microcode amdgpu-dkms-firmware already put in the guest.
    docker run --rm -v "${fw_dir}:/fw" "${ROCJITSU_IMAGE}" \
        python3 /usr/local/bin/vfio_guest_firmware.py --output /fw
    ls -l "${fw_dir}"
    [ -s "${fw_dir}/ip_discovery.bin" ] || fail "generator produced no ip_discovery.bin"

    log "staging firmware into the guest"
    guest 'rm -rf /tmp/fw && mkdir -p /tmp/fw'
    local f
    for f in "${fw_dir}"/*; do
        to_guest "${f}" "/tmp/fw/$(basename "${f}")"
    done
    guest_sh <<'GUEST'
set -euo pipefail
sudo -n install -d -m 0755 /lib/firmware/amdgpu
# Copy only what the manifest names, and into /lib/firmware/amdgpu rather than
# over /lib/firmware/updates/amdgpu, where the real packaged blobs live.
python3 - <<'PY'
import json, pathlib, subprocess
man = json.load(open("/tmp/fw/manifest.json"))
names = [f["name"] if isinstance(f, dict) else f for f in man.get("files", [])]
for name in names:
    src = pathlib.Path("/tmp/fw") / name
    subprocess.run(["sudo", "-n", "cp", str(src), f"/lib/firmware/amdgpu/{name}"],
                   check=True)
    print("staged", name)
PY
GUEST

    log "loading amdgpu against the emulated device"
    guest_sh > "${OUT}/amdgpu-load.txt" 2>&1 <<'GUEST' || { cat "${OUT}/amdgpu-load.txt"; exit 1; }
set -euo pipefail
# The emulation parameters, as upstream's qemu-vfio.md specifies them:
# discovery=2 reads ip_discovery.bin instead of polling BAR registers,
# fw_load_type=0 loads microcode directly rather than through the PSP, and
# ip_block_mask=0x3f selects the six blocks this compute-only profile has.
sudo -n modprobe amdgpu \
    discovery=2 \
    emu_mode=1 \
    fw_load_type=0 \
    vm_update_mode=3 \
    gpu_recovery=0 \
    vramlimit=256 \
    ip_block_mask=0x3f
GUEST
    cat "${OUT}/amdgpu-load.txt"

    log "qualifying the bind"
    guest_sh > "${OUT}/amdgpu-qualify.txt" 2>&1 <<'GUEST' || { cat "${OUT}/amdgpu-qualify.txt"; exit 1; }
set -euo pipefail
echo "--- driver binding ---"
ls -l /sys/bus/pci/drivers/amdgpu/ | grep -E '[0-9a-f]{4}:' \
    || { echo "amdgpu bound to nothing"; exit 1; }
echo "--- KFD node ---"
test -e /dev/kfd || { echo "no /dev/kfd"; exit 1; }
echo "--- dmesg ---"
sudo -n dmesg | grep -i amdgpu | tail -40
# The failure this driver pairing exists to avoid. A zero exit from modprobe
# does not rule it out -- the probe can fail after the module loads.
if sudo -n dmesg | grep -q 'Failed to add vcn/jpeg ip block'; then
    echo "amdgpu rejected the device (vcn/jpeg ip block)"
    exit 1
fi
GUEST
    cat "${OUT}/amdgpu-qualify.txt"

    measure_gemm
    measure_storage
    phase_down
}

# ── gemm ───────────────────────────────────────────────

measure_gemm() {
    log "building and running the GEMM benchmark"
    to_guest "${REPO_ROOT}/ubuntu-qcow2-gen/perf/sgemm-bench.hip" /tmp/sgemm-bench.hip
    if guest_env_sh "GEMM_ITERS=${GEMM_ITERS}" > "${OUT}/gemm.txt" 2>&1 <<'GUEST'
set -euo pipefail
hipcc=$(command -v hipcc || ls /opt/rocm*/bin/hipcc /opt/rocm/*/bin/hipcc 2>/dev/null | head -1)
[ -n "${hipcc}" ] || { echo "no hipcc in the guest"; exit 2; }
echo "hipcc: ${hipcc}"
# -O2 is load-bearing: at -O0 the compiler spills kernel arguments and every
# kernel gets a private segment, which rocjitsu's emulated gfx1250 cannot run.
"${hipcc}" -O2 --offload-arch=gfx1250 -o /tmp/sgemm-bench /tmp/sgemm-bench.hip
# /dev/kfd is root:render, and the guest's contract is passwordless sudo.
sudo -n /tmp/sgemm-bench "${GEMM_ITERS:-8}"
GUEST
    then
        cat "${OUT}/gemm.txt"
        local gflops
        gflops=$(sed -n 's/.*gflops=\([0-9.eE+-]*\).*/\1/p' "${OUT}/gemm.txt" | tail -1)
        if [ -n "${gflops}" ]; then
            record_metric gemm_gflops ok GFLOP/s "${gflops}" "128x128x128 FP32, validated"
        else
            record_metric gemm_gflops skip GFLOP/s "" "benchmark passed but printed no rate"
        fi
    else
        local rc=$?
        cat "${OUT}/gemm.txt" || true
        # A GEMM that runs and gets the wrong answer is a regression, not a gap.
        grep -q 'sgemm-bench: FAIL' "${OUT}/gemm.txt" \
            && fail "GEMM validation failed against the CPU reference"
        record_metric gemm_gflops skip GFLOP/s "" "benchmark did not run (exit ${rc})"
    fi
}

# ── storage ────────────────────────────────────────────
#
# The emulated NVMe namespace, read twice: once by fio through libaio into
# host memory, once by gemm-hipfile-bench through hipFile into GPU memory on
# the emulated gfx1250.
#
# The pair is the point. Neither number means much alone -- this is QEMU's
# NVMe model, so there is no media behaviour to measure and the signal is all
# submission and copy overhead -- but the two on the same filesystem in the
# same boot are a ratio, and a ratio is a thing that can regress visibly.
#
# Both read files on a mounted filesystem rather than the raw block device.
# That is not a preference: hipFile requires a filesystem path it can open
# O_DIRECT, and refuses a raw namespace. Pointing the libaio leg at the device
# and the hipFile leg at a file would have made the ratio a comparison of two
# different things.

NVME_MNT=/mnt/nvme

prepare_nvme_filesystem() {
    log "putting a filesystem on the emulated namespace"
    if guest_env_sh "NVME_MNT=${NVME_MNT}" > "${OUT}/nvme-mkfs.txt" 2>&1 <<'GUEST'
set -euo pipefail
dev=$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ { print "/dev/" $1; exit }')
[ -n "${dev}" ] || { echo "no NVMe block device in the guest" >&2; exit 2; }
echo "namespace ${dev}"
# ext4 rather than xfs: it is what the guest image already carries a mkfs for,
# and O_DIRECT behaves the same on both. -F because the namespace is fresh
# every boot and mke2fs otherwise stops to ask about the whole-device case.
sudo -n mkfs.ext4 -q -F "${dev}"
sudo -n mkdir -p "${NVME_MNT:-/mnt/nvme}"
sudo -n mount -o noatime "${dev}" "${NVME_MNT:-/mnt/nvme}"
sudo -n chmod 1777 "${NVME_MNT:-/mnt/nvme}"
df -h "${NVME_MNT:-/mnt/nvme}"
GUEST
    then
        cat "${OUT}/nvme-mkfs.txt"
        return 0
    fi
    cat "${OUT}/nvme-mkfs.txt"
    return 1
}

run_fio_libaio() {
    log "fio: libaio"
    if guest_env_sh "NVME_MNT=${NVME_MNT}" \
        > "${OUT}/fio-libaio.json" 2>"${OUT}/fio-libaio.log" <<'GUEST'
set -euo pipefail
command -v fio > /dev/null 2>&1 || { echo "no fio in the guest" >&2; exit 2; }
fio --enghelp | grep -qE '^[[:space:]]*libaio$' \
    || { echo "fio has no libaio ioengine" >&2; exit 2; }
dir="${NVME_MNT:-/mnt/nvme}"
mountpoint -q "${dir}" || { echo "${dir} is not a mount point" >&2; exit 2; }
sudo -n fio --name=seqread-libaio \
    --directory="${dir}" \
    --size=256m \
    --rw=read \
    --bs=128k \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=20 \
    --time_based \
    --output-format=json
GUEST
    then
        cat "${OUT}/fio-libaio.log" >&2 || true
        local gbs
        gbs=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
# fio reports bw in KiB/s; the trend is in GB/s decimal, as drives are sold.
print(d["jobs"][0]["read"]["bw"] * 1024 / 1e9)
' "${OUT}/fio-libaio.json")
        record_metric nvme_read_GBs ok GB/s "${gbs}" \
            "128k seq read, iodepth 32, ext4 on the emulated namespace, host memory"
    else
        local rc=$?
        cat "${OUT}/fio-libaio.log" >&2 || true
        record_metric nvme_read_GBs skip GB/s "" "libaio did not run (exit ${rc})"
    fi
}

# Our own binary rather than fio's libhipfile ioengine. It reads 1 MiB blocks
# through hipFile straight into GPU memory and then multiplies two matrices
# out of what it read, so a path that moves the right number of bytes from the
# wrong offset fails instead of scoring well. See the file's header.
run_hipfile_bench() {
    log "building and running the hipFile GEMM benchmark"
    to_guest "${REPO_ROOT}/ubuntu-qcow2-gen/perf/gemm-hipfile-bench.hip" \
        /tmp/gemm-hipfile-bench.hip
    if guest_env_sh "NVME_MNT=${NVME_MNT}" "HIPFILE_ITERS=${HIPFILE_ITERS}" \
        > "${OUT}/hipfile.txt" 2>&1 <<'GUEST'
set -euo pipefail
hipcc=$(command -v hipcc || ls /opt/rocm*/bin/hipcc /opt/rocm/*/bin/hipcc 2>/dev/null | head -1)
[ -n "${hipcc}" ] || { echo "no hipcc in the guest"; exit 2; }
# The therock packaging puts the header a directory deeper than nixl's AIS
# plugin expects, so offer both and let the source's __has_include choose.
rocm=""
for d in /opt/rocm /opt/rocm-* /opt/rocm/*; do
    [ -e "${d}/include/hipfile/hipfile.h" ] && rocm="${d}"
done
[ -n "${rocm}" ] || { echo "no hipfile.h under /opt/rocm*; is amdrocm-hipfile-dev installed?"; exit 2; }
echo "hipcc: ${hipcc}"
echo "rocm: ${rocm}"
"${hipcc}" -O2 --offload-arch=gfx1250 \
    -I"${rocm}/include" -I"${rocm}/include/hipfile" \
    -o /tmp/gemm-hipfile-bench /tmp/gemm-hipfile-bench.hip \
    -L"${rocm}/lib" -lhipfile -Wl,-rpath,"${rocm}/lib"
sudo -n /tmp/gemm-hipfile-bench "${NVME_MNT:-/mnt/nvme}" "${HIPFILE_ITERS:-4}"
GUEST
    then
        cat "${OUT}/hipfile.txt"
        local gbs registered
        gbs=$(sed -n 's/.*read_gbs=\([0-9.eE+-]*\).*/\1/p' "${OUT}/hipfile.txt" | tail -1)
        # Whether the library took the buffer, not whether we asked it to. The
        # day this flips is the day the number means something different.
        registered=$(sed -n 's/.*buf_registered=\([a-z]*\).*/\1/p' \
            "${OUT}/hipfile.txt" | tail -1)
        if [ -n "${gbs}" ]; then
            record_metric nvme_hipfile_read_GBs ok GB/s "${gbs}" \
                "1 MiB hipFileRead into GPU memory, product validated, buf_registered=${registered:-unknown}"
        else
            record_metric nvme_hipfile_read_GBs skip GB/s "" \
                "benchmark passed but printed no rate"
        fi
    else
        local rc=$?
        cat "${OUT}/hipfile.txt" || true
        # Wrong bytes is a regression, not a gap: the read succeeded and
        # delivered something other than what is on the namespace.
        grep -q 'gemm-hipfile-bench: FAIL' "${OUT}/hipfile.txt" \
            && fail "hipFile delivered operands that do not match the file"
        record_metric nvme_hipfile_read_GBs skip GB/s "" \
            "benchmark did not run (exit ${rc})"
    fi
}

measure_storage() {
    if ! prepare_nvme_filesystem; then
        record_metric nvme_read_GBs skip GB/s "" "no filesystem on the emulated namespace"
        record_metric nvme_hipfile_read_GBs skip GB/s "" "no filesystem on the emulated namespace"
        return 0
    fi
    run_fio_libaio
    run_hipfile_bench
}

# ══ phase 2: ernic ═════════════════════════════════════
#
# S3 over RDMA against the emulator's own object store, in the loopback
# deployment: one guest, one server, no peer and no TAP. The server terminates
# an HTTP control plane on the emulated NIC itself and answers each request by
# RDMA-writing object bytes into registered guest memory, so no queue pair is
# ever connected -- the rkey resolves in the emulator's own MR table. That is
# what makes a single-guest stack a complete object fabric, and it is why this
# can produce a bandwidth number where perftest would need two guests.
#
# GETs, not PUTs: a GET has the store write into guest memory, which is the
# direction the shield speaks for, and mixing the two would make the number
# mean half of each. Same choice rocm-ernic's own lane makes.

phase_ernic() {
    PHASE=ernic
    log "PHASE ernic"
    # Phase one's guest is down and its disk is the largest thing under this
    # root. Both payloads have to fit side by side otherwise, and on a hosted
    # runner that is one ephemeral disk shared with the images we pulled.
    [ "${KEEP_UP}" -eq 1 ] || sudo -n rm -rf "${VM_IMAGES_ROOT}/rocjitsu"
    extract_payload "${QCOW2_IONIC_IMAGE}" "${VM_IMAGES_ROOT}/ionic"
    ERNIC_BACKEND="s3:size=${S3_SIZE},bucket=${S3_BUCKET},ip=${S3_ADDR},port=${S3_PORT}" \
        write_env
    start_server ernic

    # The store and its in-band endpoint are created at startup, before any
    # guest touches them, so the banner is the earliest proof the backend
    # parsed its options and came up on the address the guest will ARP for.
    # Assert it here rather than inferring it from a socket timeout later.
    local banner=0
    for _ in $(seq 1 15); do
        if compose logs --no-color ernic 2>/dev/null | grep -q "s3 bucket '${S3_BUCKET}'"; then
            banner=1
            break
        fi
        sleep 2
    done
    [ "${banner}" -eq 1 ] || {
        compose logs --no-color ernic | tail -40
        fail "the ernic server logged no s3 store banner for bucket '${S3_BUCKET}'"
    }
    compose logs --no-color ernic | grep -m1 "s3 bucket"

    start_guest

    log "checking the ionic function enumerated"
    guest_sh > "${OUT}/lspci-ernic.txt" <<'GUEST'
set -euo pipefail
lspci -nn
GUEST
    cat "${OUT}/lspci-ernic.txt"
    guest "lspci -n -d ${ERNIC_PCI_VENDOR}:${ERNIC_PCI_DEVICE} | grep -q ." \
        || fail "ionic function ${ERNIC_PCI_VENDOR}:${ERNIC_PCI_DEVICE} did not attach over vfio-user"

    log "configuring the emulated NIC"
    guest_env_sh "ERNIC_PCI_VENDOR=${ERNIC_PCI_VENDOR}" \
                 "ERNIC_PCI_DEVICE=${ERNIC_PCI_DEVICE}" \
                 "S3_GUEST_ADDR=${S3_GUEST_ADDR}" \
                 "S3_GUEST_PREFIX=${S3_GUEST_PREFIX}" \
                 "S3_ADDR=${S3_ADDR}" "S3_PORT=${S3_PORT}" \
        > "${OUT}/ernic-nic.txt" 2>&1 <<'GUEST' || { cat "${OUT}/ernic-nic.txt"; exit 1; }
set -euo pipefail
bdf=$(lspci -Dn -d "${ERNIC_PCI_VENDOR}:${ERNIC_PCI_DEVICE}" | cut -d' ' -f1 | head -1)
[ -n "${bdf}" ] || { echo "no ionic function on the bus"; exit 1; }
echo "ionic bdf=${bdf}"

# Wait for ionic to claim the function and register a netdev. The module is
# in-tree on this guest's 6.18 kernel, so this is a race with module load
# rather than something that has to be built.
nic=""
for _ in $(seq 1 30); do
    nic=$(ls "/sys/bus/pci/devices/${bdf}/net" 2>/dev/null | head -1 || true)
    [ -n "${nic}" ] && break
    sleep 2
done
[ -n "${nic}" ] || {
    echo "ionic registered no netdev for ${bdf}"
    lsmod | grep -i ionic || true
    sudo -n dmesg | grep -i ionic | tail -30 || true
    exit 1
}
echo "nic=${nic}"

sudo -n ip link set "${nic}" up
# Idempotent: a re-run against a kept-up stack should not fail on EEXIST.
if ! ip -4 addr show dev "${nic}" | grep -q "${S3_GUEST_ADDR}"; then
    sudo -n ip addr add "${S3_GUEST_ADDR}/${S3_GUEST_PREFIX}" dev "${nic}"
fi
ip -4 -br addr show dev "${nic}"
ip route

# The endpoint is terminated by the emulator on this NIC, in band. If the
# connect does not complete here, nothing below it will, and the reason is on
# the server side rather than in the RDMA stack.
#
# bash's /dev/tcp rather than curl: this proves the emulator's in-band
# ARP/IPv4/TCP stack answers, which is the whole question, and it adds no
# dependency on a package the ionic flavour does not list.
for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/${S3_ADDR}/${S3_PORT}") 2>/dev/null; then
        echo "endpoint ${S3_ADDR}:${S3_PORT} accepts connections"
        exit 0
    fi
    sleep 2
done
echo "the s3 endpoint at ${S3_ADDR}:${S3_PORT} never answered"
exit 1
GUEST
    cat "${OUT}/ernic-nic.txt"

    log "waiting for the RDMA device"
    if ! guest_sh > "${OUT}/ernic-ibdev.txt" 2>&1 <<'GUEST'
set -euo pipefail
# Matched on PCI vendor rather than any device name: the kernel registers
# ionic_%d, 60-rdma-persistent-naming.rules rewrites that to rocep<bus>s<slot>,
# and a guest with rocm-ernic's udev rules rewrites it again. 0x1dd8 holds at
# every step. This is scripts/find-rdma-device.sh from rocm-ernic, inline.
dev=""
for _ in $(seq 1 45); do
    for vendor_attr in /sys/class/infiniband/*/device/vendor; do
        [ -r "${vendor_attr}" ] || continue
        read -r vendor_id < "${vendor_attr}" || continue
        [ "${vendor_id}" = 0x1dd8 ] || continue
        d=${vendor_attr%/device/vendor}
        dev=${d##*/}
        break
    done
    [ -n "${dev}" ] && break
    sleep 2
done
[ -n "${dev}" ] || {
    echo "no ionic ibv device registered"
    lsmod | grep -i ionic || true
    sudo -n dmesg | grep -i -e ionic -e ib_core | tail -40 || true
    exit 1
}
echo "rdma_device=${dev}"
for _ in $(seq 1 30); do
    ibv_devinfo -d "${dev}" | grep -q PORT_ACTIVE && break
    sleep 2
done
ibv_devinfo -d "${dev}" | grep -q PORT_ACTIVE || {
    ibv_devinfo -d "${dev}"
    echo "${dev} never reached PORT_ACTIVE"
    exit 1
}
ibv_devinfo -d "${dev}"
# The client mints its token over a GID from this table; a missing v2 entry is
# the likeliest cause of a registration that succeeds and a transfer that goes
# nowhere, so print it rather than leaving it to be guessed at.
ibv_devinfo -d "${dev}" -v | grep -A2 GID || true
GUEST
    then
        cat "${OUT}/ernic-ibdev.txt" || true
        record_metric ernic_s3_get_GBs skip GB/s "" \
            "the ionic RDMA device never came up"
        [ "${KEEP_UP}" -eq 1 ] || phase_down
        return 0
    fi
    cat "${OUT}/ernic-ibdev.txt"
    local rdma_dev
    rdma_dev=$(sed -n 's/^rdma_device=//p' "${OUT}/ernic-ibdev.txt" | head -1)
    log "rdma device ${rdma_dev}"

    measure_s3 "${rdma_dev}"
    # The last phase is the one --keep-up is for; the first is torn down
    # regardless, because the second needs the runner back.
    [ "${KEEP_UP}" -eq 1 ] || phase_down
}

measure_s3() {
    local rdma_dev=$1

    # The client comes out of the same image as the server, so both are on the
    # commit rocm-ernic-commit.txt names. A client fetched separately can
    # disagree with the server about the x-amz-rdma-token layout, and what
    # that produces is a transfer that goes nowhere.
    log "staging s3_rdma_client.c from ${ERNIC_IMAGE}"
    local cid src="${OUT}/s3_rdma_client.c"
    cid=$(docker create "${ERNIC_IMAGE}")
    if ! docker cp "${cid}:/usr/local/share/rocm-ernic/s3_rdma_client.c" "${src}" 2>/dev/null; then
        docker rm -f "${cid}" > /dev/null
        record_metric ernic_s3_get_GBs skip GB/s "" \
            "the ernic image ships no s3_rdma_client.c; rebuild it"
        return 0
    fi
    docker cp "${cid}:/usr/local/share/rocm-ernic-commit.txt" "${OUT}/ernic-commit.txt" \
        > /dev/null 2>&1 || true
    docker rm -f "${cid}" > /dev/null
    to_guest "${src}" /tmp/s3_rdma_client.c

    log "S3 over RDMA: functional checks and the size sweep"
    if guest_env_sh "S3_DEV=${rdma_dev}" "S3_ADDR=${S3_ADDR}" \
                    "S3_PORT=${S3_PORT}" "S3_BUCKET=${S3_BUCKET}" \
                    "S3_BUFFER=${S3_BUFFER}" "S3_ITERS=${S3_ITERS}" \
        > "${OUT}/s3.txt" 2>&1 <<'GUEST'
set -euo pipefail
cd /tmp
cc -O2 -Wall -Wextra -o s3_rdma_client s3_rdma_client.c -libverbs
# Registering the client's buffer needs more locked memory than the default
# 64 KiB, and the failure without it is an ibv_reg_mr that returns ENOMEM
# several layers below anything that says "memlock".
sudo -n sh -c "ulimit -l unlimited; exec /tmp/s3_rdma_client \
    -d '${S3_DEV}' -a '${S3_ADDR}' -p '${S3_PORT}' -b '${S3_BUCKET}' \
    -s '${S3_BUFFER}' -i '${S3_ITERS}' -c /tmp/s3-bw.csv"
GUEST
    then
        cat "${OUT}/s3.txt"
        grep -q 'all checks passed' "${OUT}/s3.txt" \
            || fail "the S3-over-RDMA client reported functional failures"
        # Cleared before the fetch, not after. OUT is reused verbatim between
        # local invocations and only metrics.jsonl is truncated at startup, so
        # a fetch that fails here would otherwise leave the previous run's CSV
        # in place and this run would report those numbers as its own.
        rm -f "${OUT}/s3-bw.csv"
        from_guest /tmp/s3-bw.csv "${OUT}/s3-bw.csv" || true
        if [ ! -s "${OUT}/s3-bw.csv" ]; then
            record_metric ernic_s3_get_GBs skip GB/s "" "the client wrote no sweep CSV"
            return 0
        fi
        cat "${OUT}/s3-bw.csv"
        # verb,size,bw_peak_GBs,bw_avg_GBs,msg_rate_mpps -- the schema
        # rocm-ernic's own report generator ingests, taken as it is written
        # rather than re-derived here, so the two repositories' numbers have
        # one definition. The average, not the peak: a peak on an emulator is
        # a measurement of host scheduling luck.
        local row avg peak
        row=$(awk -F, -v want="${S3_OBJECT_BYTES}" \
            '$1=="s3" && $2==want { print; exit }' "${OUT}/s3-bw.csv")
        if [ -z "${row}" ]; then
            record_metric ernic_s3_get_GBs skip GB/s "" \
                "no ${S3_OBJECT_BYTES}-byte row in the sweep"
            return 0
        fi
        peak=$(echo "${row}" | cut -d, -f3 | tr -d '\r')
        avg=$(echo "${row}" | cut -d, -f4 | tr -d '\r')
        # The row existing does not mean field 4 is a number. A short row makes
        # `cut` return empty, which record_metric would store as a null value
        # under status "ok" -- a point on the trend that claims to be a
        # measurement and is not. A non-numeric field is worse: record_metric
        # calls float() on it, raises, and takes the whole harness down under
        # set -e after the run has already been paid for.
        if ! printf '%s' "${avg}" | grep -qE '^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$'; then
            record_metric ernic_s3_get_GBs skip GB/s "" \
                "the ${S3_OBJECT_BYTES}-byte sweep row has no numeric bw_avg_GBs field (got '${avg}')"
            return 0
        fi
        record_metric ernic_s3_get_GBs ok GB/s "${avg}" \
            "$((S3_OBJECT_BYTES / 1024 / 1024)) MiB object GETs over RDMA, loopback s3 backend, peak ${peak}"
    else
        local rc=$?
        cat "${OUT}/s3.txt" || true
        compose logs --no-color ernic | tail -40 || true
        record_metric ernic_s3_get_GBs skip GB/s "" \
            "the S3-over-RDMA client did not run (exit ${rc})"
    fi
}

# ══ run ════════════════════════════════════════════════

phase_rocjitsu
phase_ernic

log "done"
