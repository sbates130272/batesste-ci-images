#!/usr/bin/env bash
#
# Run the bake on a CPU-only node of the Slurm cluster instead of on this
# workstation.
#
#   scripts/bake-slurm.sh ubuntu-base ubuntu-libvfio-user
#   scripts/bake-slurm.sh bases
#   PUSH=1 TIME=12:00:00 scripts/bake-slurm.sh ubuntu-qcow2-gen@rocjitsu
#
# Arguments are target keys (ubuntu-qcow2-gen@rocjitsu) or the job names from
# images.yml used as groups (bases, matrix, derived, or all). With no argument
# it builds everything, which is rarely what you want -- that is ~28 GB of
# ROCm and CUDA plus four guest disks.
#
# The job runs `ci-images-tool.py build`, not bake directly, so a run on the
# cluster does what a run on a workstation does: bake the images, export each
# guest payload to output/, push every tag, and push the qcow2 ORAS artifact.
# Bake is still what does the building -- `build` generates the spec and shells
# out to it -- this just means the steps either side of it are not skipped.
#
# PUSH is off by default. Nothing reaches a registry unless you ask for it,
# because the tags a build publishes move rolling aliases that consumers
# resolve through, and a half-finished experiment should not move them.
# With PUSH=1 the job needs credentials, which it reads from the repo's .env
# the same way a local build does.
#
# Docker Hub descriptions are *not* pushed here. `describe` is a pure Hub API
# call needing no builder, no daemon and no node, so run it from the login
# node afterwards -- see the README.
#
# The bake spec is generated here, on the login node, because
# source_fingerprint() needs the git checkout.
#
# Two things worth knowing about the cluster before reading on.
#
# buildx: the compute nodes ship 0.12.1 from the distro, which has no bake
# `entitlements` field (that landed in v0.17.0) and so cannot express
# security.insecure at all -- the guest builds would be unbuildable there. What
# makes this work is a newer buildx installed under ~/.local and linked into
# ~/.docker/cli-plugins, which the nodes pick up because home is shared and the
# user plugin directory outranks /usr/libexec. That is an invariant of somebody
# else's filesystem, so the job asserts it rather than assuming it.
#
# CPUONLY: the feature is applied inconsistently in this cluster --
# ctr-cx66-mi300x-01 and hpe-rack-13 advertise it while reporting MI300X and
# MI210X GRES -- so --constraint=CPUONLY narrows the pool but does not
# guarantee a GPU-free node. Harmless for a container build; set EXCLUDE if it
# ever matters.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

# The buildx that must be in play on the node. Below this, bake cannot carry
# the security.insecure entitlement the guest builds need.
MIN_BUILDX_MINOR=17

PARTITION=${PARTITION:-defq}
CONSTRAINT=${CONSTRAINT:-CPUONLY}
CPUS=${CPUS:-32}
MEM=${MEM:-64G}
# Generous by default: the guest flavours install a kernel and rebuild
# amdgpu-dkms inside a booted VM, which is an hours-long job, and a build
# killed at the wall clock has nothing to show for itself.
TIME=${TIME:-08:00:00}
EXCLUDE=${EXCLUDE:-}
JOB_NAME=${JOB_NAME:-batesste-bake}
LOG_DIR=${LOG_DIR:-$REPO_DIR/output/slurm}
# A registry layer cache, e.g. ghcr.io/<repo>/buildcache. Worth setting: a
# compute node's docker daemon is per-node, so without it every build on a node
# you have not used before starts completely cold.
#
# Passed to the job as an environment variable and not as a flag, because that
# is how it reaches bake: docker-bake.hcl declares CACHE_REGISTRY as a bake
# variable, and bake fills a variable from the environment of the process that
# runs it. Same for LOAD and CACHE_TO.
CACHE_REGISTRY=${CACHE_REGISTRY:-}

PYTHON=${PYTHON:-$REPO_DIR/.venv/bin/python}
if [[ ! -x $PYTHON ]]; then
    PYTHON=python3
fi

# A job name from images.yml stands in for the targets it covers, so
# `bases` means the same thing here as `targets --job bases` does. Expanded
# up front rather than passed through, because `build` takes target keys and
# has no notion of a group.
TARGETS=()
for t in "$@"; do
    case "$t" in
        bases | matrix | derived)
            while read -r key; do
                [[ -n $key ]] && TARGETS+=("$key")
            done < <("$PYTHON" ci-images-tool.py targets --job "$t")
            ;;
        all) ;;
        *) TARGETS+=("$t") ;;
    esac
done

PUSH_FLAG=--no-push
if [[ ${PUSH:-0} == 1 ]]; then
    PUSH_FLAG=
fi

# Generated here so that the spec the job bakes is the one this checkout
# describes. `build` regenerates it on the node from the same tree, which is
# the same answer; doing it here as well means a bad spec fails before a job
# is ever queued.
echo "Generating the bake spec on $(hostname -s)"
"$PYTHON" ci-images-tool.py bake "${TARGETS[@]}"

mkdir -p "$LOG_DIR"

SBATCH_ARGS=(
    --job-name="$JOB_NAME"
    --partition="$PARTITION"
    --constraint="$CONSTRAINT"
    --nodes=1
    --ntasks=1
    --cpus-per-task="$CPUS"
    --mem="$MEM"
    --time="$TIME"
    --output="$LOG_DIR/%x-%j.log"
)
if [[ -n $EXCLUDE ]]; then
    SBATCH_ARGS+=(--exclude="$EXCLUDE")
fi

echo "Submitting: partition=$PARTITION constraint=$CONSTRAINT cpus=$CPUS mem=$MEM time=$TIME"
echo "Targets:    ${TARGETS[*]}"
echo "Log:        $LOG_DIR/$JOB_NAME-<jobid>.log"

sbatch "${SBATCH_ARGS[@]}" \
    --export=ALL,REPO_DIR="$REPO_DIR",CACHE_REGISTRY="$CACHE_REGISTRY",MIN_BUILDX_MINOR="$MIN_BUILDX_MINOR",PUSH_FLAG="$PUSH_FLAG",PYTHON="$PYTHON" \
    /dev/stdin "${TARGETS[@]}" <<'SBATCH_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

cd "$REPO_DIR"

echo "node:    $(hostname -f)"
echo "cpus:    $(nproc)"
echo "targets: $*"

# The distro buildx on these nodes is too old to express a bake entitlement,
# so a build that silently used it would fail confusingly much later -- in the
# guest targets' case, by claiming the entitlement was never requested. Check
# up front and say which buildx is in play.
BUILDX_VERSION=$(docker buildx version | awk '{print $2}')
echo "buildx:  $BUILDX_VERSION"
BUILDX_MINOR=$(echo "${BUILDX_VERSION#v}" | cut -d. -f2)
if [[ $BUILDX_MINOR -lt $MIN_BUILDX_MINOR ]]; then
    echo "Error: buildx $BUILDX_VERSION is too old for a bake entitlement;" >&2
    echo "       v0.$MIN_BUILDX_MINOR or newer is required." >&2
    echo "       Install one under ~/.local/lib/docker/cli-plugins and link it" >&2
    echo "       into ~/.docker/cli-plugins -- home is shared, so one install" >&2
    echo "       covers every node." >&2
    exit 1
fi

# A builder of our own, with the insecure entitlement the guest builds need.
# Named for this repo rather than the bare "builder", which already exists on
# these shared nodes and belongs to somebody else -- recreating that one to fix
# its flags would throw away a stranger's cache.
BUILDER=batesste-bake
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    docker buildx create --name "$BUILDER" \
        --driver docker-container \
        --buildkitd-flags '--allow-insecure-entitlement=security.insecure --allow-insecure-entitlement=network.host' \
        >/dev/null
fi

# The guest targets boot QEMU against /dev/kvm. The device is root:kvm on the
# host and this user is not in that group, which does not matter: buildx runs
# buildkitd privileged, so the security.insecure RUN reaches it as root. What
# would matter is the device being absent, so say so here rather than let a
# minutes-long build quietly become an hours-long emulated one.
if [[ ! -e /dev/kvm ]]; then
    echo "Warning: this node has no /dev/kvm; any guest target will be" >&2
    echo "         emulated, which is roughly 10x slower." >&2
fi

# `build` rather than bake directly: it generates the spec, shells out to
# bake, and then does the things bake has no notion of -- renaming each guest
# payload into output/, pushing every tag, and pushing the qcow2 as an ORAS
# artifact. oras and zstd come from the shared home, like buildx.
#
# Credentials come from the repo's .env, which build reads itself. Without
# PUSH=1 this is --no-push and nothing leaves the node.
set -x
"$PYTHON" ci-images-tool.py build ${PUSH_FLAG:+"$PUSH_FLAG"} "$@"
SBATCH_SCRIPT
