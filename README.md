# batesste-ci-images

[![Lint](https://github.com/sbates130272/batesste-ci-images/actions/workflows/lint.yml/badge.svg)](https://github.com/sbates130272/batesste-ci-images/actions/workflows/lint.yml)
[![Dockerfile Test](https://github.com/sbates130272/batesste-ci-images/actions/workflows/dockerfile-test.yml/badge.svg)](https://github.com/sbates130272/batesste-ci-images/actions/workflows/dockerfile-test.yml)
[![Release](https://github.com/sbates130272/batesste-ci-images/actions/workflows/release.yml/badge.svg)](https://github.com/sbates130272/batesste-ci-images/actions/workflows/release.yml)
[![Latest Release](https://img.shields.io/github/v/release/sbates130272/batesste-ci-images)](https://github.com/sbates130272/batesste-ci-images/releases)
[![Python 3.12](https://img.shields.io/badge/python-3.12-blue.svg)](https://www.python.org/downloads/)
[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-sbates130272-2496ED?logo=docker&logoColor=white)](https://hub.docker.com/u/sbates130272)

This repository contains a collection of Docker images for CI/CD and
development workflows. Each image is self-contained in its own directory
with its own Dockerfile and supporting scripts. We also include a systemd
directory that enables a systemd service based flow for the automatic updating
and pushing of these images.

## Available Images

- **ubuntu-base**: Ubuntu 24.04 plus the apt tuning, shared toolchain packages
  and AMD root CA that every other image needs. Every image below is layered
  on it, so that work happens once instead of six times. See `ubuntu-base/`
  for details.
- **ubuntu-libvfio-user**: `ubuntu-base` plus libvfio-user built from the
  pinned commit. Shared by `ubuntu-qemu-libvfio-user` and `ubuntu-rocm-ernic`,
  which each used to build it separately from the same SHA. See
  `ubuntu-libvfio-user/` for details.
- **ubuntu-qemu-libvfio-user**: QEMU build with libvfio-user support for VM images
  using qemu-minimal. See `ubuntu-qemu-libvfio-user/` for details.
- **ubuntu-kernel-build**: Ubuntu-based image with tools for building Linux
  kernels and out-of-tree kernel modules. See `ubuntu-kernel-build/` for
  details.
- **ubuntu-cuda-rocm**: Toolkit-only dual-stack environment with CUDA and
  ROCm/HIP tools on Ubuntu 24.04. See `ubuntu-cuda-rocm/` for details.
- **ubuntu-cuda-rocm-fio**: `ubuntu-cuda-rocm` plus fio built from a pinned
  upstream commit with both direct-to-GPU storage engines enabled:
  `libhipfile` (AMD hipFile) and `libcufile` (NVIDIA GPUDirect Storage). Also
  published as `…-ubuntu-cuda-rocm-fio-async-hipfile`, the same Dockerfile
  built against AMD's fork branch adding asynchronous hipFile submission
  (`hipfile_mode=batch|stream`) — see [Image Variants](#image-variants). See
  `ubuntu-cuda-rocm-fio/` for details.
- **ubuntu-rocm-nixl**: `ubuntu-cuda-rocm` plus UCX, NIXL, and NIXLBench built
  with ROCm/HIP support for AMD GPUs. See `ubuntu-rocm-nixl/` for details.
- **ubuntu-rocm-ernic**: Ubuntu 24.04 image with libvfio-user and rocm-ernic
  built from pinned source commits. Designed for RDMA/ERNIC development and
  CI. See `ubuntu-rocm-ernic/` for details.
- **ubuntu-rocm-rocjitsu**: Ubuntu 24.04 image with rocjitsu built from a
  pinned source commit with `-DROCJITSU_ENABLE_VFIO=ON`. Provides a
  software-emulated AMD GPU vfio-user server for KFD/amdgpu bring-up without
  real hardware. Currently tracks the `users/agutierr/gfx1250-vfio-compute-wip`
  branch rather than `develop`, since the vfio-compute work only exists there.
  See `ubuntu-rocm-rocjitsu/` for details.
- **ubuntu-qcow2-gen**: Guest VM disk images (qcow2), not a runnable container.
  Built on `ubuntu-qemu-libvfio-user` and published `FROM scratch` with nothing
  but `/output` in it, one Docker Hub repository per flavour
  (`…-ubuntu-qcow2-gen`, `…-ubuntu-qcow2-gen-ionic`). See
  [Guest VM images](#guest-vm-images-ubuntu-qcow2-gen) and `ubuntu-qcow2-gen/`.

### rocjitsu vfio-user mode

Simulation configs are installed by upstream's own CMake install rule at
`/usr/local/share/rocjitsu/configs` (also exported as `ROCJITSU_CONFIG_DIR`),
and build provenance is at `/usr/local/share/rocjitsu-build.json`.

Only `gfx1250_mi455x.json` can be served over vfio-user. Upstream publishes an
IP discovery table for exactly one target -- `kGfx1250TargetVersion` (120500) in
`lib/rocjitsu/src/rocjitsu/vm/amdgpu/pci/gpu_pci_device_spec.cpp` -- and a
config with any other `gfx_target_version` leaves the device unusable, so
`rocjitsu --vfio-socket` logs `no IP discovery profile` and exits 1. The image
build runs a smoke test that starts the server and waits for `vfu: serving`, so
this fails at build time rather than at deploy time.

#### Guest bring-up tools

Booting amdgpu against the emulator needs two artefacts the guest cannot
produce for itself, so the image ships the tools that generate them:

| Tool | Generates |
| --- | --- |
| `rj-ip-discovery gfx1250 <out>` | `ip_discovery.bin`, staged at `/lib/firmware/amdgpu/ip_discovery.bin` and read with `amdgpu.discovery=2` |
| `vfio_guest_firmware.py --output <dir>` | the five GFX/SDMA/MES firmware stubs (`gc_12_1_0_{imu,mec,rlc_1,uni_mes}.bin`, `sdma_7_1_0.bin`) |

Without the discovery table the driver polls BAR registers for a completion
bit rocjitsu never sets and spins at 99% CPU in `gfx_v12_1_hw_init`; without
the firmware stubs it cannot get through `early_init`. The stubs carry only
header metadata and rocjitsu sentinel payloads — they are not AMD microcode.

Upstream builds `rj-ip-discovery` but has no `install()` rule for it, so the
image lifts it out of the build tree; both tools are smoke-tested at build
time, as the vfio-user probe is.

The VMM must share guest RAM through an mmap-able descriptor or the device
cannot reach it. With QEMU that means a `memory-backend-memfd` with `share=on`
plus `-machine memory-backend=mem`; `ubuntu-qemu-libvfio-user`'s entrypoint sets
this up automatically when `VFIO_USER_SOCKET` is set. `compose/docker-compose.yml`
wires the two together over the shared `vfio-sockets` volume.

## Project Structure

```
batesste-ci-images/
├── ubuntu-base/               # Shared apt preamble + AMD root CA
│   └── Dockerfile
├── ubuntu-libvfio-user/       # ubuntu-base + libvfio-user at the pinned SHA
│   └── Dockerfile
├── ubuntu-qemu-libvfio-user/  # QEMU libvfio-user image
│   ├── Dockerfile
│   └── entrypoint.sh
├── ubuntu-kernel-build/       # Kernel build environment
│   ├── Dockerfile
│   └── README.md
├── ubuntu-cuda-rocm/          # CUDA + ROCm toolchains
│   ├── Dockerfile
│   ├── README.md
│   ├── cuda-latest
│   └── rocm-latest
├── ubuntu-cuda-rocm-fio/      # fio with libhipfile + libcufile engines
│   ├── Dockerfile
│   └── README.md
├── ubuntu-rocm-nixl/          # NIXL and NIXLBench with ROCm/HIP support
│   ├── Dockerfile
│   ├── README.md
│   └── patches/nixl/
├── ubuntu-rocm-ernic/         # libvfio-user + rocm-ernic build environment
│   └── Dockerfile
├── ubuntu-rocm-rocjitsu/      # rocjitsu vfio-user emulated GPU image
│   └── Dockerfile
├── ubuntu-qcow2-gen/          # Guest qcow2 images, one flavour per variant
│   ├── Dockerfile
│   ├── build-vm.sh
│   ├── probe-guest.sh
│   ├── packages/              # cloud-init package manifests per flavour
│   └── checks/                # In-guest assertions run at build time
├── common/                    # Shared build-context assets
│   └── amd-root-ca.crt
├── compose/                   # Docker Compose stacks
│   └── docker-compose.yml
├── scripts/                   # Repository maintenance scripts
│   └── check-readme-structure.sh
├── systemd/                   # Systemd service files
│   ├── build-vm.service
│   └── build-vm.timer
├── images.yml                 # Single source of truth: pins, tags, variants
├── ci-images-tool.py          # Python CLI for build/push/inspect
├── requirements.txt           # Python dependencies
├── .python-version            # Python version pin (3.12)
├── env.example                # Machine-local environment configuration
└── README.md
```

## Prerequisites

- Docker installed and running
- Python 3.12+ (for the CLI tool)
- Systemd (for automated daily rebuilds, optional)
- Additional prerequisites may be required per image (see
  individual image documentation)

## Quick Start

### 0. Set Up the Python Virtual Environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 1. Build Docker Images

Build all images at once:

```bash
./ci-images-tool.py build
```

Or build a specific image:

```bash
./ci-images-tool.py build ubuntu-qemu-libvfio-user
```

Preview the docker commands without executing them:

```bash
./ci-images-tool.py build --dry-run
```

Specify a password file for registry authentication:

```bash
./ci-images-tool.py build \
  ubuntu-qemu-libvfio-user \
  --password-file /path/to/password.txt
```

#### Image Layering and Build Caches

The images form a chain rather than eight independent builds:

```text
ubuntu-base ─┬─ ubuntu-cuda-rocm ── ubuntu-cuda-rocm-fio
             ├─ ubuntu-kernel-build
             ├─ ubuntu-rocm-rocjitsu
             └─ ubuntu-libvfio-user ─┬─ ubuntu-qemu-libvfio-user
                                     └─ ubuntu-rocm-ernic
```

`ci-images-tool.py build` orders the images so every base is built before its
dependants. Each Dockerfile takes a `BASE_IMAGE` build arg that defaults to the
*published* base on Docker Hub, so building one leaf image on its own never
rebuilds the chain above it. That default only resolves for someone who has not
run `docker login` if the base repositories are public, so all of them are. When a base *is* built in the same run, the
dependant falls back to the `default` builder, which cannot grant
`security.insecure` — so `ubuntu-qemu-libvfio-user`, whose VM build needs
`/dev/kvm`, errors out rather than building without it. Pass
`--base-from-registry` to keep every image on the buildx builder and retain
KVM, or set registry credentials so the base is published before its dependant
is built.

Two caches are in play:

- **Layer cache.** CI exports to a registry cache on GHCR
  (`ghcr.io/<repo>/buildcache`) rather than `type=gha`, because the GitHub
  Actions cache is capped at 10 GB per repository and these images evicted each
  other out of it faster than they could be reused. This means the test
  workflow needs `packages: write`, which pull requests from forks do not get;
  those runs still build correctly, just without cache reuse.
- **Cache mounts.** Every `apt-get` step mounts `/var/cache/apt` and
  `/var/lib/apt/lists`, and the QEMU, fio, rocm-ernic and rocjitsu compile steps
  mount a ccache directory. BuildKit does not export cache mounts, so these help
  repeated local builds, not CI.

### 1a. List and Inspect Images

List all images, or every build target including variants:

```bash
./ci-images-tool.py list
./ci-images-tool.py targets
```

Inspect a locally-built image (size, layers, tags):

```bash
./ci-images-tool.py inspect ubuntu-qemu-libvfio-user
```

Check what tags exist on the remote registry:

```bash
./ci-images-tool.py status
```

Show the tags and labels an image would be published under, without
building it:

```bash
./ci-images-tool.py tags ubuntu-cuda-rocm --tag 1.1.0
./ci-images-tool.py labels ubuntu-cuda-rocm --tag 1.1.0
```

### 1b. Push Images Separately

Build first, then push as a separate step:

```bash
./ci-images-tool.py build ubuntu-qemu-libvfio-user
./ci-images-tool.py push ubuntu-qemu-libvfio-user
```

You can also build images directly with Docker:

```bash
docker build -f <image-directory>/Dockerfile \
  -t batesste-ci-images-<image-directory>:latest \
  <image-directory>
```

Each image may support different build arguments. See the
individual image documentation for details.

### 2. Configure Environment Variables

Some images may require environment configuration. Copy the example
environment file and customize as needed:

```bash
cp env.example .env
# Edit .env with your desired configuration
```

Note: Not all images require environment configuration. Check individual
image documentation for requirements.

### 3. Using Images

Each image has its own purpose and usage. See the individual image
directories for specific usage instructions. Common patterns include:

- Running containers with specific entrypoints
- Building artifacts or images
- Running CI/CD workflows
- Development environments

Refer to each image's documentation for detailed usage examples.

## Configuration

### images.yml

`images.yml` is the single source of truth for everything that is not the
Dockerfile itself: the pinned upstream versions, the build args they map to,
the tag variant, the OCI labels, which image each one layers on, and which CI
job builds it. `ci-images-tool.py` is a generic engine over that file — adding
an image means adding a Dockerfile and an entry, with no Python change.

Each entry declares its pins as *vars*:

```yaml
  ubuntu-rocm-rocjitsu:
    job: matrix
    base: ubuntu-base
    vars:
      rocjitsu_commit:
        value: 5e9cc7c57d372c0198fd8decb1fe5ceb07038a2b
        env: ROCM_ROCJITSU_COMMIT
    build_args:
      ROCJITSU_COMMIT: "{rocjitsu_commit}"
    variant: "rocjitsu.{rocjitsu_commit|short}"
```

A var can be overridden from the environment for a one-off local build, using
the `env:` name (defaulting to the var name upper-cased). Read the current
values back through the tool rather than grepping the YAML:

```bash
./ci-images-tool.py config ubuntu-rocm-rocjitsu
./ci-images-tool.py config ubuntu-rocm-rocjitsu --get rocjitsu_commit
./ci-images-tool.py validate      # every target renders; run in CI lint
```

`scripts/version-scrub.sh` reads pins the same way and writes bumps back to
`images.yml` (plus the matching Dockerfile `ARG` fallback), so the pins cannot
drift between the tool, the workflows and the Dockerfiles the way they used to.

#### Local overlay

An optional `images.local.yml` beside `images.yml` is deep-merged over it when
present: dictionaries merge key by key, anything else replaces. It is
gitignored and CI never reads it, so a published image always matches the spec
in the tree.

Unlike an environment override it can reach *anything* — including a variant's
own pins, since writing the file is a deliberate act rather than a stray
variable — and it can declare targets that do not exist upstream:

```yaml
images:
  ubuntu-rocm-rocjitsu:
    variants:
      scratch:
        suffix: "-scratch"
        vars:
          rocjitsu_commit: <sha you are testing>
```

```bash
./ci-images-tool.py build ubuntu-rocm-rocjitsu@scratch
```

Because it silently changes what every tag and build arg resolves to, the tool
prints `note: images.local.yml applied over images.yml` on stderr whenever it
is in effect, and `validate` names both files. Delete the file to go back to
the checked-in spec.

### Environment variables

`images.yml` is checked in and describes what gets built; `.env` is not checked
in and covers the two things it cannot hold — secrets (registry credentials),
and settings belonging to the machine rather than the repository: whether this
host has `/dev/kvm`, and the knobs `compose` and `entrypoint.sh` read when a
container *runs* (`SSH_PORT`, `VCPUS`, `VMEM`, `VFIO_USER_SOCKET`), which are
not build inputs at all.

Copy `env.example` to get started. Pinned versions are not duplicated there,
and neither are values `images.yml` already owns: entries are left blank
because an empty value means "unset", so the `images.yml` default applies.

Common configuration variables:

- `REGISTRY`: OCI registry URL (default: `docker.io` for Docker Hub)
- `REGISTRY_IMAGE`: Base image name in registry (default: `batesste-ci-images`)
  - Final image names will be `{REGISTRY_USERNAME}/{REGISTRY_IMAGE}-{image-directory}`
    (e.g., `username/batesste-ci-images-ubuntu-qemu-libvfio-user`)
  - If `REGISTRY_IMAGE` contains a `/`, it's used as-is
  - If `REGISTRY_USERNAME` is set, it's prepended automatically
- `REGISTRY_USERNAME`: Registry username for authentication (required for Docker Hub)
- `REGISTRY_PASSWORD`: Registry password or token for authentication
  - Can be a direct password or a path to a file containing the password
- `REGISTRY_PASSWORD_FILE`: Alternative way to specify password file path
- `IMAGE_TAG`: Base tag to publish under (`auto` = today's UTC date in ISO
  basic form, e.g. `20260526`; a semver such as `1.1.0` also publishes the
  rolling `1.1` and `latest` aliases). See [Image Tags](#image-tags).
- `WORKDIR`: Working directory for builds (defaults to script directory)

The `ci-images-tool.py` CLI also supports:
- `--password-file FILE`: specify a password file
- `--env-file PATH`: override the `.env` search path
- Automatically reads `.env` from script directory, current
  directory, or `/etc/batesste-ci-images/.env` (in order)

Image-specific variables are documented in each image's directory and declared
in `images.yml`. For example, the `ubuntu-qemu-libvfio-user` image may use
variables like `QEMU_COMMIT`, `VM_NAME`, `USERNAME`, etc.

### Image Tags

An image's tag carries both the repository release and the payload that
distinguishes the build, so two releases with different ROCm or fio versions
are told apart without pulling them. The payload half is the *variant*:

| Image | Variant |
| --- | --- |
| `ubuntu-cuda-rocm` | `rocm10.0-cuda13.4` |
| `ubuntu-cuda-rocm-fio` | `rocm10.0-cuda13.4-fio.<sha>` |
| `ubuntu-rocm-ernic` | `ernic.<sha>-vfu.<sha>` |
| `ubuntu-rocm-rocjitsu` | `rocjitsu.<sha>` |
| `ubuntu-rocm-nixl` | `nixl.<sha>-ucx.<sha>` |
| `ubuntu-qemu-libvfio-user` | `qemu11.1.1-vfu.<sha>` |
| `ubuntu-kernel-build` | `ubuntu24.04` |

`<sha>` is the pinned upstream commit abbreviated to seven characters;
`vfu` is libvfio-user, which both of those images link against. The variants
are templates in `images.yml`, so they follow the pins automatically.

Releasing git tag `v1.1.0` publishes `ubuntu-cuda-rocm` as:

```text
1.1.0-rocm10.0-cuda13.4   immutable, fully specified -- pin this in CI
1.1-rocm10.0-cuda13.4     rolling patch within this variant
rocm10.0-cuda13.4         rolling latest of this variant
1.1.0                     release alias
1.1                       rolling minor alias
latest                    rolling
sha-<short>               provenance, traceable to a commit
```

The git tag keeps its `v` prefix; the image tag drops it, per OCI convention.
A local `ci-images-tool.py build` uses the same scheme with `IMAGE_TAG` as the
base, so `IMAGE_TAG=auto` yields `20260526-rocm10.0-cuda13.4`.

The same facts are recorded as OCI labels, so they can be read without parsing
a tag:

```bash
docker image inspect --format '{{json .Config.Labels}}' <image> | jq
```

`ci-images-tool.py` owns the scheme; release CI calls it rather than
duplicating the logic:

```bash
./ci-images-tool.py tags ubuntu-cuda-rocm --tag 1.1.0
./ci-images-tool.py labels ubuntu-cuda-rocm --tag 1.1.0
```

### Image Variants

One Dockerfile can publish more than one image. A *variant* is the same
Dockerfile built with some vars overlaid — typically a different upstream ref —
and each variant gets its own repository, named by suffixing the image
directory, so it keeps its own `latest` and its own rolling aliases instead of
racing the default build for them.

| Target | Repository |
| --- | --- |
| `ubuntu-cuda-rocm-fio` | `…-ubuntu-cuda-rocm-fio` |
| `ubuntu-cuda-rocm-fio@async-hipfile` | `…-ubuntu-cuda-rocm-fio-async-hipfile` |
| `ubuntu-qemu-libvfio-user` | `…-ubuntu-qemu-libvfio-user` |
| `ubuntu-qemu-libvfio-user@sbates-fork` | `…-ubuntu-qemu-libvfio-user-sbates-fork` |

Refer to one on the command line as `<image>@<variant>`; every subcommand that
takes an image takes a target:

```bash
./ci-images-tool.py targets                   # every target
./ci-images-tool.py build ubuntu-cuda-rocm-fio@async-hipfile
./ci-images-tool.py tags ubuntu-cuda-rocm-fio@async-hipfile --tag 1.2.0
```

Declaring one is an overlay on the image's own entry:

```yaml
    variants:
      async-hipfile:
        suffix: "-async-hipfile"
        vars:
          fio_repo: https://github.com/ROCm/fio.git
          fio_commit: c32261752c88b3f7aadfde4d011a028ae954f869
```

A variant's pins are deliberately immune to environment overrides, and
`scripts/version-scrub.sh` never touches them: a variant exists precisely to
sit at a ref of its own, so bumping it to branch HEAD would defeat the point.
The default target keeps tracking branch HEAD as before.

### Immutable Builds

For reproducible builds, images may support build arguments or environment
variables to pin specific versions or commit hashes; the checked-in pins live
in `images.yml`. See individual image documentation for details on how to
configure immutable builds.

## Automated Daily Rebuilds

To set up automated daily rebuilds at 3am:

### 1. Install Service Files

```bash
sudo cp systemd/build-vm.service /etc/systemd/system/
sudo cp systemd/build-vm.timer /etc/systemd/system/
sudo cp ci-images-tool.py /opt/batesste-ci-images/
sudo cp requirements.txt /opt/batesste-ci-images/
sudo chmod +x /opt/batesste-ci-images/ci-images-tool.py
sudo python3 -m venv /opt/batesste-ci-images/.venv
sudo /opt/batesste-ci-images/.venv/bin/pip install \
  -r /opt/batesste-ci-images/requirements.txt
sudo mkdir -p /opt/batesste-ci-images/output
sudo mkdir -p /etc/batesste-ci-images
sudo cp .env /etc/batesste-ci-images/.env
```

### 2. Configure Registry Push (Optional)

To push Docker images to an OCI registry (e.g., Docker Hub), edit
`/etc/batesste-ci-images/.env` and add:

```bash
REGISTRY=docker.io
REGISTRY_IMAGE=your-username/batesste-ci-images
REGISTRY_USERNAME=your-username
REGISTRY_PASSWORD=your-password-or-token
IMAGE_TAG=latest
```

Note: When using `ci-images-tool.py`, images are named
`{REGISTRY}/{REGISTRY_IMAGE}-{image-directory}` and published under the tag
set described in [Image Tags](#image-tags).

**Security Note**: For production, consider using Docker credential helpers or
storing the password in a secure location with restricted permissions (e.g.,
`/etc/batesste-ci-images/.env` with `chmod 600`).

For Docker Hub, you can use a Personal Access Token instead of your password:
1. Go to Docker Hub → Account Settings → Security
2. Create a new access token
3. Use the token as `REGISTRY_PASSWORD`

### 3. Update Service File Paths

Edit `/etc/systemd/system/build-vm.service` to match your system paths if
needed. The service will:
1. Build the Docker image(s) using `ci-images-tool.py`
2. Push the image(s) to the configured registry (if
   credentials are provided)
3. Optionally run containers or build artifacts
   (image-specific)

### 4. Enable and Start Timer

```bash
sudo systemctl daemon-reload
sudo systemctl enable build-vm.timer
sudo systemctl start build-vm.timer
```

### 5. Check Timer Status

```bash
sudo systemctl status build-vm.timer
sudo systemctl list-timers build-vm.timer
```

## Manual Service Execution

To manually trigger a build:

```bash
sudo systemctl start build-vm.service
```

Check logs:

```bash
sudo journalctl -u build-vm.service -f
```

## Image-Specific Documentation

Each image directory contains its own documentation and may have different:
- Build requirements and arguments
- Runtime requirements and capabilities
- Output formats and locations
- Usage patterns and examples

Refer to the README or documentation in each image directory for specific
details.

### ubuntu-qemu-libvfio-user VM Image Output

The `ubuntu-qemu-libvfio-user` build creates a VM disk image during the Docker
build process, using `qemu-tool gen-vm` from the pinned `QEMU_MINIMAL_REPO`
checkout. Set `QEMU_MINIMAL_REPO=none` in `.env` to skip the VM build.
The VM image, SSH keys, and metadata are stored in `/output/` within the container:

- **VM Disk Image**: `/output/{VM_NAME}.qcow2` - The QEMU disk image file
- **SSH Keys**: `/output/id_rsa` and `/output/id_rsa.pub` - SSH private and public
  keys generated during VM build
- **VM Metadata**: `/output/vm-info.json` - JSON file containing VM configuration
  and build information

#### KVM is required

The VM build boots a real guest, so it needs `/dev/kvm` on the build host and a
BuildKit builder started with
`--allow-insecure-entitlement=security.insecure`; `ci-images-tool.py` creates
(or recreates) its `builder` that way automatically.

There is no TCG fallback. Emulation is roughly 10× slower, which turns a
minutes-long build into an hours-long one — and it used to do so silently, on
exactly the runs nobody was watching. When either precondition is missing the
build now fails with an error naming the cause and the remedy. Building the
Dockerfile directly (without `ci-images-tool.py`) therefore requires
`--allow security.insecure`.

CI relies on this. x86 GitHub-hosted runners do expose `/dev/kvm`, but as
`root:kvm 0660`, which the BuildKit `RUN` step cannot open; the workflows
install a udev rule widening it to `0666` before creating the builder. Runners
with no `/dev/kvm` at all — ARM Linux, macOS, Windows, `ubuntu-slim` — cannot
build guest images.

#### vm-info.json Format

The `vm-info.json` file contains the following information:

```json
{
  "vm_name": "batesste-ci-vm",
  "username": "batesste",
  "password": "changeme",
  "image_path": "/output/batesste-ci-vm.qcow2",
  "image_format": "qcow2",
  "image_size_bytes": 1234567890,
  "release": "resolute",
  "architecture": "amd64",
  "qemu_path": "/opt/qemu/bin/",
  "kvm_enabled": true,
  "backing_file": false,
  "ssh_keys": {
    "private_key_path": "/output/id_rsa",
    "public_key_path": "/output/id_rsa.pub"
  },
  "build_info": {
    "qemu_commit": "abc123...",
    "libvfio_user_commit": "def456...",
    "qemu_minimal_commit": "ghi789...",
    "build_timestamp": "2025-01-01T12:00:00Z"
  }
}
```

This metadata file can be used by automation tools or scripts to programmatically
access VM configuration without needing to parse environment variables or inspect
the image directly.

To access the VM image and metadata from a built container:

```bash
docker run --rm \
  -v /path/to/output:/output \
  your-registry/ubuntu-qemu-libvfio-user:latest \
  cat /output/vm-info.json
```

Or mount the `/output` directory when running the container to access both the
VM image and metadata file.

### Guest VM images (ubuntu-qcow2-gen)

`ubuntu-qemu-libvfio-user` bakes in one guest as a side effect of building the
QEMU toolchain. `ubuntu-qcow2-gen` makes guests a first-class artefact family
instead: one parameterised Dockerfile, one catalogue entry per flavour, one
Docker Hub repository each.

The published image is `FROM scratch` — a pure payload with no runtime, nothing
to patch and no CVE surface. Consume it either way:

```bash
cid=$(docker create sbates130272/batesste-ci-images-ubuntu-qcow2-gen-ionic:latest)
docker cp "$cid:/output/." ./vm && docker rm "$cid"
jq . vm/vm-info.json
```

```dockerfile
COPY --from=sbates130272/batesste-ci-images-ubuntu-qcow2-gen-ionic:latest /output /output
```

Guests default to Ubuntu 26.04 LTS "resolute" (Linux 7.0), set once in
`defaults.vars.release`; a flavour needing something else pins its own. That
chooses the *userspace* only — see `kernel_ref` below.

Each flavour is provisioned in three layers:

- `ubuntu-qcow2-gen/packages/<flavour>.txt` — extra cloud-init packages,
  appended to qemu-minimal's default manifest.
- `vm_playbook` — an Ansible playbook from the pinned qemu-minimal checkout,
  for what cloud-init cannot express (source builds, git checkouts, units).
  Playbook *content* lives upstream, so it stays shared with the non-container
  `qemu-tool` workflows.
- `kernel_ref` — an [Ubuntu mainline](https://kernel.ubuntu.com/mainline/)
  build tag, for a kernel no Ubuntu archive has. Mainline publishes one build
  per version rather than one per release and depends on only a handful of base
  packages, so this is orthogonal to `release`: `ionic` is resolute userspace,
  whose GA kernel is 7.0, running a mainline 7.2.3 kernel instead. The `.deb`s
  are loose files in no apt repository and
  cloud-init has no hook to run a command, so they are installed in a
  provisioning boot of its own, after cloud-init and before verification. The
  build fails if the guest then boots anything other than the pinned kernel.

The build then boots the finished qcow2 from a throwaway overlay and runs
`ubuntu-qcow2-gen/checks/<flavour>.sh` inside it over SSH. That reads the guest
kernel out (it is not knowable beforehand, which is why it is in
`vm-info.json` rather than in the tag) and fails the build — rather than the
consumer — if the guest cannot boot or is missing what its flavour promised.

Adding a flavour is a `packages/<name>.txt`, a `checks/<name>.sh` and a
`variants:` entry in `images.yml`. Repository, tag set, labels, CI matrix row
and verification all follow; no workflow or Python change.

Where a flavour exists for a specific downstream consumer, what that consumer
needs and how it will use the image is written down in
`ubuntu-qcow2-gen/consumers/<name>.md`, so the reason a flavour exists outlives
the conversation that created it.

`vm-info.json` is `schema_version` 2 here: every v1 key above is unchanged, and
`flavour`, `kernel_release` and a `provisioning` object (`vm_packages`,
`packages_digest`, `vm_playbook`, `kernel_ref`, `kernel_debs`) are added.
`kernel_debs` carries the resolved filenames, upstream build stamp included,
because a mainline tag alone does not identify a build.

Like every VM build, this needs KVM — see [KVM is required](#kvm-is-required).

#### Bare qcow2 artifacts (ORAS)

The release workflow also publishes each guest disk as a bare OCI artifact, so
a libvirt or bare-metal consumer can fetch a disk without a container runtime
and address it by its own digest:

```bash
./ci-images-tool.py push-artifact ubuntu-qcow2-gen@ionic --tag 1.2.0
```

It extracts `/output` from the published scratch image, compresses the qcow2
with zstd, pushes it under `application/vnd.batesste.vm-image.v1`, and attaches
`vm-info.json` as a referrer. Artifact tags carry a `-qcow2` suffix
(`--tag-suffix`) so they share the flavour's repository with the scratch image
instead of overwriting it. Requires `oras` and `zstd` on `PATH`.

```bash
oras pull docker.io/sbates130272/batesste-ci-images-ubuntu-qcow2-gen-ionic:latest-qcow2
oras discover docker.io/sbates130272/batesste-ci-images-ubuntu-qcow2-gen-ionic:latest-qcow2
```

## Adding New Images

To add a new image:

1. Create a new directory (e.g., `my-new-image/`)
2. Add a `Dockerfile` in that directory (required)
3. Add any supporting scripts or files as needed (e.g., `entrypoint.sh`,
   `build.sh`, etc.)
4. Add documentation (README.md) in the image directory describing:
   - What the image does
   - Build requirements and arguments
   - Usage examples
   - Configuration options
5. Add an entry under `images:` in `images.yml` giving at least its `job:`
   (`bases`, `matrix` or `derived`), its `base:`, and any pinned `vars` with
   the `build_args` and `variant` they feed. Run `./ci-images-tool.py validate`
6. Update this top-level README to list the new image in the "Available
   Images" section
7. The `ci-images-tool.py` CLI and both CI workflows pick it up from
   `images.yml` — no workflow change is needed to *build* it. Any per-image
   smoke test still has to be added to `dockerfile-test.yml` by hand, gated
   on `matrix.target.image`, alongside the existing ones

The image directory name will be used as part of the Docker image tag:
`{REGISTRY_IMAGE}-{image-directory}:{IMAGE_TAG}`

### Image Directory Structure

Each image directory should contain:
- `Dockerfile` (required) - The Docker image definition
- Supporting scripts (optional) - Scripts used by the image
- Documentation (recommended) - README.md or other docs explaining usage

Example structure:

```
my-new-image/
├── Dockerfile
├── entrypoint.sh      # Optional
├── build.sh           # Optional
└── README.md          # Recommended
```
