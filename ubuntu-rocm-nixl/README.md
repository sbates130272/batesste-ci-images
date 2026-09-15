# ubuntu-rocm-nixl

Ubuntu 24.04 image containing NIXL and NIXLBench built with ROCm/HIP support
for AMD GPUs. UCX is built from source with its ROCm transport enabled before
NIXL and NIXLBench are built.

libfabric is built from source too. NIXL only uses HIP in its libfabric plugin
-- `rocm_dep` and the hipify translation are consumed under `src/utils/libfabric`
and `src/plugins/libfabric` and nowhere else -- so without it the ROCm support
in this image would come from UCX alone and nothing in NIXL would link HIP.

Abseil, gRPC and etcd-cpp-apiv3 are also built from source. Ubuntu's
`libgrpc++-dev` depends on an Abseil that predates `absl_log`, and NIXL refuses
to build against a partial Abseil rather than mix two versions at runtime;
etcd-cpp-apiv3 needs gRPC, and it is NIXLBench's only distributed runtime. The
Abseil and gRPC pins match those upstream NIXL uses for its own ROCm image.

The image uses the ROCm installation path recorded by
`ubuntu-cuda-rocm` in `/etc/rocm-path`, so it works with both the legacy and
therock ROCm layouts.

## Build

```bash
./ci-images-tool.py build ubuntu-rocm-nixl
```

The source revisions can be overridden with the `NIXL_TAG`, `UCX_COMMIT`,
`ETCD_COMMIT`, `ABSL_TAG`, `GRPC_TAG` and `LIBFABRIC_TAG` Docker build
arguments. NIXL is built from a tagged release rather than a bare commit; the
commit that tag resolved to is recorded in `/usr/local/share/nixl-commit.txt`
alongside the tag itself in `nixl-tag.txt`. Files ending in `.patch` placed in
`patches/nixl/` are applied to the pinned NIXL checkout before it is
configured.

NIXL's release branches declare fewer meson options than its main branch, and
meson aborts on an unknown one, so the `-D` options are passed through
`scripts/meson-supported-opts.sh`, which forwards only those the pinned tree
declares and reports the rest on stderr. This lets one Dockerfile build both a
release tag and main, so a `NIXL_TAG` bump neither breaks the build nor
silently drops an option a newer tree supports.

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
