# batesste-ci-images

This repository contains a collection of Docker images for CI/CD and
development workflows. Each image is self-contained in its own directory
with its own Dockerfile and supporting scripts. We also include a systemd
directory that enables a systemd service based flow for the automatic updating
and pushing of these images.

## Available Images

- **ubuntu-qemu-libvfio-user**: QEMU build with libvfio-user support for VM images
  using qemu-minimal. See `ubuntu-qemu-libvfio-user/` for details.
- **ubuntu-kernel-build**: Ubuntu-based image with tools for building Linux
  kernels and out-of-tree kernel modules. See `ubuntu-kernel-build/` for
  details.

## Project Structure

```
batesste-ci-images/
├── ubuntu-qemu-libvfio-user/  # QEMU libvfio-user image
│   ├── Dockerfile
│   ├── build-vm.sh
│   └── entrypoint.sh
├── ubuntu-kernel-build/       # Kernel build environment
│   ├── Dockerfile
│   └── README.md
├── systemd/                    # Systemd service files
│   ├── build-vm.service
│   └── build-vm.timer
├── build-and-push.sh          # Script to build and push all images
├── env.example                # Example environment configuration
└── README.md
```

## Prerequisites

- Docker installed and running
- Systemd (for automated daily rebuilds, optional)
- Additional prerequisites may be required per image (see individual
  image documentation)

## Quick Start

### 1. Build Docker Images

To build all images at once, use the `build-and-push.sh` script:

```bash
./build-and-push.sh
```

Or build a specific image:

```bash
./build-and-push.sh ubuntu-qemu-libvfio-user
```

To specify a password file for registry authentication:

```bash
./build-and-push.sh ubuntu-qemu-libvfio-user --password-file /path/to/password.txt
```

You can also build images directly with Docker:

```bash
docker build -f <image-directory>/Dockerfile \
  -t batesste-ci-images-<image-directory>:latest \
  <image-directory>
```

Each image may support different build arguments. See the individual image
documentation for details.

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
- `IMAGE_TAG`: Image tag to use (default: `latest`)
- `WORKDIR`: Working directory for builds (defaults to script directory)

The `build-and-push.sh` script also supports:
- `--password-file FILE`: Command-line option to specify password file
- Automatically reads `.env` from script directory, current directory, or
  `/etc/batesste-ci-images/.env` (in that order)

Image-specific variables are documented in each image's directory. For
example, the `ubuntu-qemu-libvfio-user` image may use variables like
`QEMU_COMMIT`, `VM_NAME`, `USERNAME`, etc.

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
sudo cp build-and-push.sh /opt/batesste-ci-images/
sudo chmod +x /opt/batesste-ci-images/build-and-push.sh
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

Note: When using `build-and-push.sh`, images will be tagged as
`{REGISTRY}/{REGISTRY_IMAGE}-{image-directory}:{IMAGE_TAG}`. For example,
with `REGISTRY_IMAGE=batesste-ci-images` and `IMAGE_TAG=latest`, the
ubuntu-qemu-libvfio-user image will be tagged as
`docker.io/batesste-ci-images-ubuntu-qemu-libvfio-user:latest`.

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
1. Build the Docker image(s) using `build-and-push.sh`
2. Push the image(s) to the configured registry (if credentials are provided)
3. Optionally run containers or build artifacts (image-specific)

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
6. The `build-and-push.sh` script will automatically discover and build it

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

