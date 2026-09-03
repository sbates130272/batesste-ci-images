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
  `libhipfile` (AMD hipFile) and `libcufile` (NVIDIA GPUDirect Storage). See
  `ubuntu-cuda-rocm-fio/` for details.
- **ubuntu-rocm-ernic**: Ubuntu 24.04 image with libvfio-user and rocm-ernic
  built from pinned source commits. Designed for RDMA/ERNIC development and
  CI. See `ubuntu-rocm-ernic/` for details.
- **ubuntu-rocm-rocjitsu**: Ubuntu 24.04 image with rocjitsu built from a
  pinned source commit with `-DROCJITSU_ENABLE_VFIO=ON`. Provides a
  software-emulated AMD GPU vfio-user server for KFD/amdgpu bring-up without
  real hardware. See `ubuntu-rocm-rocjitsu/` for details.

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
├── ubuntu-rocm-ernic/         # libvfio-user + rocm-ernic build environment
│   └── Dockerfile
├── ubuntu-rocm-rocjitsu/      # rocjitsu vfio-user emulated GPU image
│   └── Dockerfile
├── common/                    # Shared build-context assets
│   └── amd-root-ca.crt
├── compose/                   # Docker Compose stacks
│   └── docker-compose.yml
├── scripts/                   # Repository maintenance scripts
│   └── check-readme-structure.sh
├── systemd/                   # Systemd service files
│   ├── build-vm.service
│   └── build-vm.timer
├── ci-images-tool.py          # Python CLI for build/push/inspect
├── requirements.txt           # Python dependencies
├── .python-version            # Python version pin (3.12)
├── env.example                # Example environment configuration
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
`security.insecure` — `ubuntu-qemu-libvfio-user` then builds its VM under TCG
instead of KVM. Pass `--base-from-registry` to keep every image on the buildx
builder and retain KVM.

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

List all discoverable image directories:

```bash
./ci-images-tool.py list
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

The `env.example` file provides example environment variables that may be
used by various images. Not all images require all variables. See
individual image documentation for specific requirements.

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

Image-specific variables are documented in each image's directory. For
example, the `ubuntu-qemu-libvfio-user` image may use variables like
`QEMU_COMMIT`, `VM_NAME`, `USERNAME`, etc.

### Image Tags

An image's tag carries both the repository release and the payload that
distinguishes the build, so two releases with different ROCm or fio versions
are told apart without pulling them. The payload half is the *variant*:

| Image | Variant |
| --- | --- |
| `ubuntu-cuda-rocm` | `rocm7.14-cuda13.3` |
| `ubuntu-cuda-rocm-fio` | `rocm7.14-cuda13.3-fio.<sha>` |
| `ubuntu-rocm-ernic` | `ernic.<sha>-vfu.<sha>` |
| `ubuntu-rocm-rocjitsu` | `rocjitsu.<sha>` |
| `ubuntu-qemu-libvfio-user` | `qemu11.1.1-vfu.<sha>` |
| `ubuntu-kernel-build` | none |

`<sha>` is the pinned upstream commit abbreviated to seven characters;
`vfu` is libvfio-user, which both of those images link against.

Releasing git tag `v1.1.0` publishes `ubuntu-cuda-rocm` as:

```text
1.1.0-rocm7.14-cuda13.3   immutable, fully specified -- pin this in CI
1.1-rocm7.14-cuda13.3     rolling patch within this variant
rocm7.14-cuda13.3         rolling latest of this variant
1.1.0                     release alias
1.1                       rolling minor alias
latest                    rolling
sha-<short>               provenance, traceable to a commit
```

The git tag keeps its `v` prefix; the image tag drops it, per OCI convention.
A local `ci-images-tool.py build` uses the same scheme with `IMAGE_TAG` as the
base, so `IMAGE_TAG=auto` yields `20260526-rocm7.14-cuda13.3`.

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

### Immutable Builds

For reproducible builds, images may support build arguments or environment
variables to pin specific versions or commit hashes. See individual image
documentation for details on how to configure immutable builds.

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

#### KVM acceleration

The VM build runs with KVM by default (`KVM=true`), which needs `/dev/kvm` on
the build host and a BuildKit builder started with
`--allow-insecure-entitlement=security.insecure`; `ci-images-tool.py` creates
(or recreates) its `builder` that way automatically.

When either is missing the build does not fail: the tool prints a warning and
selects the `vm-tcg` Dockerfile stage instead of `vm-kvm`, so the VM is built
under TCG emulation — same result, much slower. `KVM=false` forces that path.
Building the Dockerfile directly (without `ci-images-tool.py`) defaults to the
`vm-kvm` stage, so pass `--allow security.insecure`, or
`--build-arg VM_STAGE=vm-tcg` to opt out.

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
  "release": "noble",
  "architecture": "amd64",
  "qemu_path": "/opt/qemu/bin/",
  "kvm_enabled": false,
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
5. Update this top-level README to list the new image in the "Available
   Images" section
6. The `ci-images-tool.py` CLI will automatically
   discover and build it

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
