#!/bin/bash
#
# hipfile-smoke.sh
#
# Drive the libhipfile engine's submission modes against a real AMD GPU and a
# hipFile-capable filesystem, one fio example job per mode.
#
# Shipped by every ubuntu-cuda-rocm-fio target. The async modes only exist in
# the @async-hipfile variant, so the default mode list is taken from what the
# build recorded rather than assumed.

set -u

EXAMPLES=/usr/local/share/fio/examples
ASYNC_MARKER=/usr/local/share/fio-hipfile-async.txt

# hipFile's batch backend accepts submissions but performs no I/O, and
# GetStatus/Destroy return "Not Implemented" (see the note in
# examples/libhipfile-batch.fio). A batch run is therefore expected to fail
# until that lands, and is reported as SKIP unless --strict-batch is given.
strict_batch=0

dir=${FIO_DIR:-/mnt/nvme}
gpu_ids=${GPU_DEV_IDS:-0}
sections="read write"
modes=""

usage() {
    cat <<'EOF'
usage: hipfile-smoke.sh [-d DIR] [-g GPU_IDS] [-m MODES] [-s SECTIONS]
                        [--strict-batch] [-h]

  -d DIR       directory on a hipFile-capable filesystem (default: $FIO_DIR
               or /mnt/nvme)
  -g GPU_IDS   value for the engine's gpu_dev_ids option (default:
               $GPU_DEV_IDS or 0)
  -m MODES     space-separated subset of: posix sync stream batch
               (default: every mode this build supports)
  -s SECTIONS  space-separated job-file sections to run
               (default: "read write"; use "all" for the whole job file)
  --strict-batch
               treat a batch failure as a failure instead of a skip

Each mode runs the matching example job from
/usr/local/share/fio/examples/. Exits non-zero if any mode fails.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) dir=$2; shift 2 ;;
        -g) gpu_ids=$2; shift 2 ;;
        -m) modes=$2; shift 2 ;;
        -s) sections=$2; shift 2 ;;
        --strict-batch) strict_batch=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "hipfile-smoke.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

async=no
if [ -r "$ASYNC_MARKER" ]; then
    async=$(cat "$ASYNC_MARKER")
fi

if [ -z "$modes" ]; then
    if [ "$async" = yes ]; then
        modes="sync stream batch"
    else
        modes="sync"
    fi
fi

# Job file per mode. posix and sync differ only in rocm_io, so they are
# separate example files rather than a mode flag.
job_file() {
    case "$1" in
        posix)  echo "$EXAMPLES/libhipfile-posix.fio" ;;
        sync)   echo "$EXAMPLES/libhipfile-hipfile.fio" ;;
        stream) echo "$EXAMPLES/libhipfile-stream.fio" ;;
        batch)  echo "$EXAMPLES/libhipfile-batch.fio" ;;
        *)      echo "" ;;
    esac
}

fail() { echo "hipfile-smoke.sh: $1" >&2; exit 1; }

# ── preflight ──────────────────────────────────────────

command -v fio > /dev/null 2>&1 || fail "fio is not on PATH"

fio --enghelp 2>/dev/null | grep -qE '^[[:space:]]*libhipfile$' \
    || fail "this fio has no libhipfile engine"

# Usage errors before hardware: a typo in -m should not be reported as a
# missing GPU.
for mode in $modes; do
    file=$(job_file "$mode")
    [ -n "$file" ] || fail "unknown mode '$mode'"
    if [ ! -f "$file" ]; then
        if [ "$mode" = stream ] || [ "$mode" = batch ]; then
            fail "mode '$mode' needs the asynchronous engine; this image was \
built from upstream fio. Use the ubuntu-cuda-rocm-fio-async-hipfile image."
        fi
        fail "missing job file $file"
    fi
done

[ -d "$dir" ] || fail "directory '$dir' does not exist (mount it, or pass -d)"
[ -w "$dir" ] || fail "directory '$dir' is not writable"

[ -e /dev/kfd ] || fail "/dev/kfd is missing -- run with --device=/dev/kfd \
--device=/dev/dri --group-add video"

# ── run ────────────────────────────────────────────────

export FIO_DIR="$dir"
export GPU_DEV_IDS="$gpu_ids"

section_args=""
if [ "$sections" != all ]; then
    for section in $sections; do
        section_args="$section_args --section=$section"
    done
fi

echo "hipfile-smoke.sh: dir=$dir gpu_dev_ids=$gpu_ids modes='$modes' \
sections='$sections'"
echo "fio: $(fio --version), commit $(cat /usr/local/share/fio-commit.txt \
2>/dev/null || echo unknown)"

results=""
status=0

# batch last: it is the mode expected to fail, so the useful output stays
# closest to the summary when it does.
ordered=""
for mode in $modes; do
    [ "$mode" = batch ] || ordered="$ordered $mode"
done
for mode in $modes; do
    [ "$mode" = batch ] && ordered="$ordered $mode"
done

for mode in $ordered; do
    echo
    echo "=== hipfile_mode=$mode ==============================="
    # shellcheck disable=SC2086
    if fio $section_args "$(job_file "$mode")"; then
        results="$results $mode:PASS"
        continue
    fi
    if [ "$mode" = batch ] && [ "$strict_batch" -eq 0 ]; then
        echo "--- batch failed, as expected: the hipFile batch backend is not"
        echo "--- implemented yet. Pass --strict-batch to make this fatal."
        results="$results $mode:SKIP"
        continue
    fi
    results="$results $mode:FAIL"
    status=1
done

echo
echo "=== summary ==========================================="
for result in $results; do
    echo "  ${result%%:*}: ${result##*:}"
done

exit "$status"
