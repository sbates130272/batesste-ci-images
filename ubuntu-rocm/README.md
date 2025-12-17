# ubuntu-rocm

Docker image for AMD ROCm development and CI/CD workflows.

## Overview

This image provides a complete environment for:
- Building and running ROCm applications
- HIP development and compilation
- ROCm library development
- CI/CD workflows requiring ROCm support

## Base Image

- Ubuntu 24.04

## Installed Packages

### ROCm Stack
- `rocm` - Complete ROCm meta-package including:
  - ROCm runtime libraries
  - HIP compiler and runtime
  - ROCm development tools
  - ROCm libraries (rocBLAS, rocFFT, etc.)

### Prerequisites
- `libstdc++-14-dev` - C++ standard library development files
- `python3-setuptools` - Python setuptools
- `python3-wheel` - Python wheel package format
- `pciutils` - PCI utilities (for GPU detection)

## Build Arguments

- `ROCM_VERSION` - ROCm version to install (default: `latest`)
  - Set to `latest` to automatically detect and install the latest
    available ROCm version
  - Set to a specific version (e.g., `6.1.0`) to install that version
- `CACHE_BUST` - Optional cache-busting argument to force rebuilds

## Usage

### Building the Image

Build with default (latest) ROCm version:

```bash
docker build -f ubuntu-rocm/Dockerfile \
  -t batesste-ci-images-ubuntu-rocm:latest \
  ubuntu-rocm
```

Build with a specific ROCm version:

```bash
docker build -f ubuntu-rocm/Dockerfile \
  --build-arg ROCM_VERSION=6.1.0 \
  -t batesste-ci-images-ubuntu-rocm:6.1.0 \
  ubuntu-rocm
```

Or use the build script:

```bash
./build-and-push.sh ubuntu-rocm
```

### Running ROCm Applications

```bash
docker run --rm -it \
  --device=/dev/kfd \
  --device=/dev/dri \
  --security-opt seccomp=unconfined \
  batesste-ci-images-ubuntu-rocm:latest \
  rocminfo
```

### Building HIP Applications

```bash
docker run --rm -it \
  -v $(pwd)/hip-source:/build \
  batesste-ci-images-ubuntu-rocm:latest \
  bash -c "cd /build && hipcc -o program program.cpp"
```

### Environment Variables

The image sets up the following environment variables:

- `PATH` - Includes `/opt/rocm/bin`
- `LD_LIBRARY_PATH` - Includes `/opt/rocm/lib` and `/opt/rocm/lib64`
- `ROCM_VERSION` - The ROCm version installed in the image

### ROCm Library Paths

The following library paths are configured:
- `/opt/rocm/lib` - ROCm libraries
- `/opt/rocm/lib64` - ROCm 64-bit libraries
- `/opt/rocm/bin` - ROCm executables

These paths are automatically added to `LD_LIBRARY_PATH` and `PATH`
environment variables.

## Version Detection

When `ROCM_VERSION=latest` is specified (the default), the image uses
the `rocm-latest` script to automatically detect the latest available
ROCm version from the AMD repository. The script queries:
- `https://repo.radeon.com/rocm/apt/` for ROCm versions
- `https://repo.radeon.com/amdgpu/` for AMDGPU driver versions

## Notes

- This image is designed for CI/CD and development environments
- For production GPU workloads, ensure proper GPU access is configured
- The image includes ROCm repositories configured for Ubuntu 24.04
- ROCm packages are pinned with priority 600 to ensure ROCm packages
  are preferred over system packages
