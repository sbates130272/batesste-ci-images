# ubuntu-cuda-rocm-fio

fio built with both vendors' direct-to-GPU storage engines, layered on
`ubuntu-cuda-rocm`.

## Overview

This image adds a single `fio` binary that supports:

- `libhipfile` — AMD hipFile (ROCm direct-to-GPU I/O)
- `libcufile` — NVIDIA cuFile / GPUDirect Storage
- CUDA GPU memory buffers (`mem=cudamalloc`, from `--enable-cuda`)

Everything else comes from the base image: CUDA toolkit under
`/usr/local/cuda`, ROCm/HIP under the path recorded in `/etc/rocm-path`.
As with the base, this is **toolkit-only** — GPU drivers are host-provided.

> hipFile is an early-access technology preview. AMD does not recommend it
> for production workloads.

## Base image

- `${BASE_IMAGE}`, default
  `docker.io/sbates130272/batesste-ci-images-ubuntu-cuda-rocm:latest`

The base must be built with `ROCM_STREAM=therock`. The legacy
`repo.radeon.com` stream does not publish `amdrocm-hipfile-dev`, and the
build fails early with a message saying so.

## Build arguments

### `BASE_IMAGE`

The `ubuntu-cuda-rocm` image to layer on. `ci-images-tool.py` fills this in
automatically with the locally-tagged base for the current `IMAGE_TAG`;
override with `FIO_BASE_IMAGE` in `.env`.

### `FIO_REPO`

- Default: `https://github.com/axboe/fio.git`

### `FIO_COMMIT`

- Default: a pinned `master` commit SHA

`libhipfile` landed on fio master as commit `67256d4e` (2026-05-08) and is
not in the `fio-3.42` tag, so this pin must track master until the engine
appears in a release. `scripts/version-scrub.sh` advances it automatically.

### `CACHE_BUST`

Optional build arg supported by this repo convention. Set it to force a
rebuild when you change scripts or logic.

## Build

```bash
./ci-images-tool.py build ubuntu-cuda-rocm-fio
```

Or directly with Docker:

```bash
docker build -f ubuntu-cuda-rocm-fio/Dockerfile \
  --build-arg BASE_IMAGE=batesste-ci-images-ubuntu-cuda-rocm:latest \
  -t batesste-ci-images-ubuntu-cuda-rocm-fio:latest \
  .
```

## Why fio runs without an NVIDIA driver

fio's `configure` appends a bare `-lcuda` to the global link line once CUDA
support is enabled, so the binary carries `DT_NEEDED libcuda.so.1` and
cannot start unless that library is present — not even `fio --version`.
That would make the image unusable for `libhipfile` work on AMD-only hosts.

It works anyway because the base image installs NVIDIA's `cuda-compat`,
providing a real `libcuda.so.1` at the lowest linker precedence. On a host
with an NVIDIA driver the driver wins; with no driver, compat is used and
fio still starts. See [CUDA driver
resolution](../ubuntu-cuda-rocm/README.md#cuda-driver-resolution).

This only lets fio *load*. `--ioengine=libcufile` still needs a real NVIDIA
GPU and driver, and fails at `cuInit()` without one.

## Verify (no GPU required)

```bash
docker run --rm \
  batesste-ci-images-ubuntu-cuda-rocm-fio:latest \
  bash -lc '
    fio --version
    cat /usr/local/share/fio-commit.txt
    fio --enghelp | grep -E "libhipfile|libcufile"
    ldd "$(command -v fio)" | grep -E "libcuda|libhipfile"
  '
```

Expected: both engine names are listed, `libhipfile.so.0` resolves under
`/opt/rocm/lib`, and `libcuda.so.1` resolves under `.../compat/` on a
driverless host. The compiled-in engine list is also snapshotted at
`/usr/local/share/fio-engines.txt` and the exact fio commit at
`/usr/local/share/fio-commit.txt`.

## Runtime notes (GPU drivers are host-provided)

### AMD GPU usage

Requires host AMD drivers plus `/dev/kfd` and `/dev/dri`:

```bash
docker run --rm -it \
  --device=/dev/kfd \
  --device=/dev/dri \
  --group-add video \
  --security-opt seccomp=unconfined \
  -v /mnt/nvme:/mnt/nvme \
  batesste-ci-images-ubuntu-cuda-rocm-fio:latest \
  fio --name=hipfile-read \
      --ioengine=libhipfile \
      --gpu_dev_ids=0 \
      --rw=read --bs=1m --size=1g --direct=1 \
      --filename=/mnt/nvme/testfile
```

Engine options: `gpu_dev_ids` selects the HIP device(s); `rocm_io` selects
the I/O path. hipFile falls back to POSIX I/O when the direct-to-GPU path is
unavailable.

### NVIDIA GPU usage

Requires host NVIDIA drivers and nvidia-container-toolkit:

```bash
docker run --rm -it --gpus all \
  -v /mnt/nvme:/mnt/nvme \
  batesste-ci-images-ubuntu-cuda-rocm-fio:latest \
  fio --name=cufile-read \
      --ioengine=libcufile \
      --gpu_dev_ids=0 \
      --rw=read --bs=1m --size=1g --direct=1 \
      --filename=/mnt/nvme/testfile
```

Both engines need a filesystem and block device that support the vendor's
direct-to-GPU path; otherwise they fall back to (or refuse) buffered I/O.

## References

<!-- References -->
[fio-upstream]:
  https://github.com/axboe/fio
[fio-libhipfile]:
  https://github.com/axboe/fio/blob/master/engines/libhipfile.c
[hipfile]:
  https://rocm.docs.amd.com/projects/hipFile/en/latest/index.html
[cufile]:
  https://docs.nvidia.com/gpudirect-storage/
