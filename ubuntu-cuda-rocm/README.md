# ubuntu-cuda-rocm

Toolkit-only dual-stack image for CUDA and ROCm on Ubuntu 24.04.

## Overview

This image is intended for CI/CD and developer workflows that need both
toolchains available in one container:

- CUDA toolkit (`nvcc`, libraries under `/usr/local/cuda`)
- ROCm/HIP development stack (compiler tools under `/opt/rocm`)

It is **toolkit-only**: no GPU kernel drivers are installed in the
container. You provide those from the host.

One exception on the NVIDIA side: the CUDA toolkit ships only a *link-time*
stub for `libcuda`, so any binary linking `-lcuda` cannot even start
without the host driver. The image therefore installs NVIDIA's
`cuda-compat` package, which provides a real `libcuda.so.1` under
`$(cat /etc/cuda-path)/compat`. See [CUDA driver
resolution](#cuda-driver-resolution) below.

The image also avoids embedding a single mixed `LD_LIBRARY_PATH` in
`Dockerfile` `ENV`. Instead, it provides per-stack environment scripts
in `/etc/profile.d/`.

## Base image

- `ubuntu:24.04`

## Installed toolchain components

The exact CUDA and ROCm versions are selected via build args:

- `CUDA_VERSION`
- `ROCM_VERSION`

For `latest`, the image uses:

- `/usr/local/bin/cuda-latest` (NVIDIA repo parsing)
- `/usr/local/bin/rocm-latest` (AMD repo parsing)

Resolved values are written to:

- `/etc/cuda-version`
- `/etc/rocm-version`
- `/etc/rocm-stream`

## Install roots

The two toolkit roots are probed at build time and recorded, because the
layout differs by ROCm stream:

- `/etc/rocm-path` — `/opt/rocm` on the legacy stream, but
  `/opt/rocm/core-<version>` on the therock stream, which nests everything
  one level down and creates no `/opt/rocm/{bin,lib,include}`
- `/etc/cuda-path` — normally `/usr/local/cuda`, falling back to the
  highest-versioned `/usr/local/cuda-*`

`/etc/ld.so.conf.d/{rocm,cuda}.conf` and the `/etc/profile.d/` scripts are
both derived from these files, so downstream images should read them rather
than hardcoding paths:

```bash
ROCM_PATH="$(cat /etc/rocm-path)"
CUDA_PATH="$(cat /etc/cuda-path)"
```

## CUDA driver resolution

`libcuda.so.1` is the userspace half of the NVIDIA kernel driver and is not
part of the CUDA toolkit — the toolkit ships only a 74 KB link-time stub at
`${CUDA_PATH}/lib64/stubs/libcuda.so`, whose functions are error-returning
trampolines. Anything linking `-lcuda` therefore fails to start with:

```
error while loading shared libraries: libcuda.so.1: cannot open shared
object file: No such file or directory
```

To make such binaries usable on machines without an NVIDIA driver — AMD-only
hosts and CI runners — the image installs `cuda-compat-${CUDA_VERSION}`
(NVIDIA's CUDA Forward Compatibility package) and registers it at the
**lowest** linker precedence:

| Path | Source | Wins when |
| --- | --- | --- |
| `/usr/lib/x86_64-linux-gnu/libcuda.so.1` | host driver, injected by nvidia-container-toolkit | running under `--gpus` |
| `${CUDA_PATH}/compat/libcuda.so.1` | `cuda-compat` in this image | no host driver present |

`ld.so.conf.d` is processed in glob order, so `zz-cuda-compat.conf` sorts
after `x86_64-linux-gnu.conf` and a host-injected driver always takes
precedence. Nothing needs `LD_LIBRARY_PATH` in either case.

`/etc/cuda-compat-installed` records `yes`/`no`. If a pinned `CUDA_VERSION`
has no matching `cuda-compat` package the build warns and continues, and
binaries linking `-lcuda` then require a host driver as before.

Note that compat only lets such a binary *load*. Actual CUDA calls still
need a real GPU and driver; without one they fail at `cuInit()`.

## Build arguments

### `CUDA_VERSION`

- Default: `latest`
- Behavior:
  - `latest` installs the highest `cuda-toolkit-M-N` available
  - otherwise installs `cuda-toolkit-${CUDA_VERSION}`

### `ROCM_VERSION`

- Default: `latest`
- Behavior:
  - `latest` uses `latest` for both `/rocm/apt/` and `/amdgpu/` apt repos
    (and still records the detected ROCm version for traceability)
  - otherwise uses that value for both apt repos

Note: the ROCm and amdgpu repo path version strings do not always match.
If you find that a pinned `ROCM_VERSION` fails during `apt-get update`,
try `ROCM_VERSION=latest`.

### `CACHE_BUST`

Optional build arg supported by this repo convention. It can be set to
force rebuilds when you change scripts or logic.

## Build

### Default (latest)

```bash
docker build -f ubuntu-cuda-rocm/Dockerfile \
  -t batesste-ci-images-ubuntu-cuda-rocm:latest \
  ubuntu-cuda-rocm
```

### Pinned CUDA and ROCm

```bash
docker build -f ubuntu-cuda-rocm/Dockerfile \
  --build-arg CUDA_VERSION=13-2 \
  --build-arg ROCM_VERSION=latest \
  -t batesste-ci-images-ubuntu-cuda-rocm:13-2-latest-rocm \
  ubuntu-cuda-rocm
```

## Verify (no GPU required)

Run these inside the container:

```bash
docker run --rm -it \
  batesste-ci-images-ubuntu-cuda-rocm:latest \
  bash -lc '
    echo "CUDA:"; cat /etc/cuda-version;
    nvcc --version || true;
    echo;
    echo "ROCm:"; cat /etc/rocm-version;
    hipcc --version || true;
    ls -la /opt/rocm || true;
  '
```

Expected:

- `nvcc --version` works (CUDA toolkit installed)
- `hipcc --version` works (ROCm/HIP tools installed)

## Runtime notes (GPU drivers are host-provided)

### NVIDIA GPU usage

Typical container run pattern (requires host NVIDIA drivers and
nvidia-container-toolkit):

```bash
docker run --rm -it --gpus all \
  batesste-ci-images-ubuntu-cuda-rocm:latest \
  bash -lc "nvcc --version"
```

### AMD GPU usage

Typical container run pattern for ROCm/HIP in a container
(requires host AMD drivers and `/dev/kfd` + `/dev/dri`):

```bash
docker run --rm -it \
  --device=/dev/kfd \
  --device=/dev/dri \
  --group-add video \
  --security-opt seccomp=unconfined \
  batesste-ci-images-ubuntu-cuda-rocm:latest \
  bash -lc "hipcc --version"
```

## References

<!-- References -->
[nvidia-ubuntu2404-packages]:
  https://developer.download.nvidia.com/compute/cuda/repos/
  ubuntu2404/x86_64/Packages
[nvidia-cuda-keyring]:
  https://developer.download.nvidia.com/compute/cuda/repos/
  ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
[amdgpu-rocm-apt]:
  https://repo.radeon.com/rocm/apt/latest/
[amdgpu-apt-base]:
  https://repo.radeon.com/amdgpu/latest/ubuntu/

