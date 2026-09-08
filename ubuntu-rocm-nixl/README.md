# ubuntu-rocm-nixl

Ubuntu 24.04 image containing NIXL and NIXLBench built with ROCm/HIP support
for AMD GPUs. UCX is built from source with its ROCm transport enabled before
NIXL and NIXLBench are built.

The image uses the ROCm installation path recorded by
`ubuntu-cuda-rocm` in `/etc/rocm-path`, so it works with both the legacy and
therock ROCm layouts.

## Build

```bash
./ci-images-tool.py build ubuntu-rocm-nixl
```

The source revisions can be overridden with `NIXL_COMMIT` and `UCX_COMMIT`
Docker build arguments. Files ending in `.patch` placed in `patches/nixl/` are
applied to the pinned NIXL checkout before it is configured.

## Run

AMD GPU access requires the host ROCm devices:

```bash
docker run --rm -it \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video \
  --security-opt seccomp=unconfined \
  batesste-ci-images-ubuntu-rocm-nixl:latest \
  nixlbench --help
```
