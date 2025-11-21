# batesste-ci-images

This repository contains Docker-based tooling to build QEMU from source and
create VM images using the qemu-minimal repository.

## Overview

The Dockerfile builds:
- QEMU from the latest Git tag with slirp-based networking support
- A VM image using qemu-minimal's gen-vm script with cloud-init

## Prerequisites

- Docker installed and running
- Access to the qemu-minimal repository (expected at
  `/home/stebates/Projects/qemu-minimal`)
- Systemd (for automated daily rebuilds)

## Quick Start

### 1. Build the Docker Image

Build with a specific QEMU commit hash for reproducibility:

```bash
# Get latest QEMU commit hash
QEMU_COMMIT=$(git ls-remote https://gitlab.com/qemu-project/qemu.git HEAD | cut -f1)

# Build with specific commit
docker build --build-arg QEMU_COMMIT=${QEMU_COMMIT} \
  -t batesste-ci-images:latest .
```

Or use HEAD (latest) for development:

```bash
docker build -t batesste-ci-images:latest .
```

### 2. Configure Environment Variables

Copy the example environment file and customize:

```bash
cp env.example .env
# Edit .env with your desired VM_NAME, USERNAME, PASSWORD, and commit hashes
```

### 3. Build the VM Image

```bash
docker run --rm \
  -v /home/stebates/Projects/qemu-minimal:/build/qemu-minimal \
  -v $(pwd)/output:/output \
  -v $(pwd)/.env:/build/.env:ro \
  batesste-ci-images:latest
```

The VM image will be created in the `output/` directory.

## Configuration

Edit the `.env` file to customize:

- `USERNAME`: Username for the VM (default: `batesste`)
- `VM_NAME`: Name of the VM image (default: `${USERNAME}-ci-vm`, e.g., `batesste-ci-vm`)
- `PASSWORD`: Password for the VM user (default: `changeme`)
- `QEMU_COMMIT`: QEMU commit hash (set at build time via `--build-arg`)
- `QEMU_MINIMAL_COMMIT`: qemu-minimal commit hash for immutable builds
- `QEMU_MINIMAL_REPO`: Repository URL if cloning qemu-minimal (optional)

### Immutable Builds

For reproducible builds, specify commit hashes:

1. **QEMU Commit**: Set via `--build-arg QEMU_COMMIT=<hash>` when building
   the Docker image

2. **qemu-minimal Commit**: Set `QEMU_MINIMAL_COMMIT` in `.env` file. The
   script will checkout this commit before building the VM.

Example `.env`:

```bash
VM_NAME=batesste-ci-vm
USERNAME=batesste
PASSWORD=changeme
QEMU_MINIMAL_COMMIT=abc123def456...
```

To get the latest commit hash:

```bash
# QEMU
git ls-remote https://gitlab.com/qemu-project/qemu.git HEAD | cut -f1

# qemu-minimal (if you have it cloned)
cd /path/to/qemu-minimal && git rev-parse HEAD
```

## Automated Daily Rebuilds

To set up automated daily rebuilds at 3am:

### 1. Install Service Files

```bash
sudo cp build-vm.service /etc/systemd/system/
sudo cp build-vm.timer /etc/systemd/system/
sudo mkdir -p /opt/batesste-ci-images/output
sudo mkdir -p /etc/batesste-ci-images
sudo cp .env /etc/batesste-ci-images/.env
```

### 2. Update Service File Paths

Edit `/etc/systemd/system/build-vm.service` to match your system paths if
needed.

### 3. Enable and Start Timer

```bash
sudo systemctl daemon-reload
sudo systemctl enable build-vm.timer
sudo systemctl start build-vm.timer
```

### 4. Check Timer Status

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

## Output

The VM images are created in the output directory:
- `{VM_NAME}.qcow2` - The VM disk image
- `{VM_NAME}-backing.qcow2` - The backing file (if using backing files)

Commit hashes used for the build are saved in the container at:
- `/build/qemu-commit.txt` - QEMU commit hash
- `/build/qemu-minimal-commit.txt` - qemu-minimal commit hash (if specified)

These can be copied out of the container for verification and reproducibility.

## QEMU Build Details

The Dockerfile builds QEMU with:
- Target: x86_64-softmmu (for qemu-system-x86_64)
- Slirp networking support enabled
- Static linking
- Installed to `/opt/qemu/bin/` in the container

## Notes

- The qemu-minimal repository is mounted read-only into the container
- The output directory should be writable by the Docker user
- The build process generates an SSH key if one doesn't exist
- Cloud-init is used to configure the VM with the specified username and
  password

