# ubuntu-libvfio-user

Ubuntu with [libvfio-user](https://gitlab.com/qemu-project/libvfio-user) built
and installed from source.

## Overview

`libvfio-user` implements the vfio-user protocol, which lets a device be
emulated by a process outside the VMM and attached to a guest over a Unix
socket. More than one image in this collection links against it, so it is built
once here and shared rather than rebuilt per image.

Two images layer on this one:

- [`ubuntu-qemu-libvfio-user`](../ubuntu-qemu-libvfio-user/) — QEMU built with
  vfio-user client support, the side that *consumes* a device
- [`ubuntu-rocm-ernic`](../ubuntu-rocm-ernic/) — an RDMA NIC device server, the
  side that *provides* one

Sharing the layer also means both see the same pin. The commit is part of both
images' tags, so two builds that differ only in the libvfio-user pin cannot
collide.

## Base image

- [`ubuntu-base`](../ubuntu-base/)

## What is installed

- `libvfio-user` built with meson/ninja and installed under `/usr/local`, so
  downstream images find it at the prefix they build against
- its build dependencies: `meson`, `libglib2.0-dev`, `libjson-c-dev`,
  `libcmocka-dev`

The resolved commit is recorded in the image at
`/usr/local/share/libvfio-user-commit.txt`, which is also the container's
default command:

```bash
docker run --rm \
  docker.io/sbates130272/batesste-ci-images-ubuntu-libvfio-user:latest
```

## Usage

To build against it:

```dockerfile
ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-libvfio-user:latest
FROM ${BASE_IMAGE}
```

## Pin

The commit is pinned in [`images.yml`](../images.yml) as
`libvfio_user_commit`, under `defaults.vars` because more than one image needs
it. `scripts/version-scrub.sh` advances it, and the README badge that
advertises it is generated from the same value.

`libvfio_user_repo` sits beside it, so a variant can point the build at a
different tree without touching the Dockerfile.

## Variants

| Variant | Repository suffix | What differs |
| --- | --- | --- |
| *(default)* | *(none)* | Upstream libvfio-user from `qemu-project`, at the pinned commit |
| `sbates-fork` | `-sbates-fork` | The `sbates130272` fork's `feat/host-doorbell-fd`, adding `VFIO_USER_HOST_DOORBELL_FD` (opcode 19), `vfu_setup_host_doorbell_cb()` and `vfu_mmio_write()` |

The fork branch is rebased onto the commit `libvfio_user_commit` names, so the
variant is that tree plus the doorbell series rather than a divergent one. It
is force-pushed as the series is reworked, so the variant pins a SHA and
`version-scrub.sh` — which tracks `qemu-project` master — deliberately cannot
see it.

It offers two ways to reach host MMIO without a `REGION_WRITE` round trip: a
per-doorbell eventfd pushed up front by the client, rung with a single
`eventfd_write()`; and `vfu_mmio_write()`, a `DMA_WRITE` to an MMIO GPA needing
no prior registration, for writes with no dedicated doorbell fd. Both only help
a server that calls them; this image just makes them available. `ubuntu-qemu-libvfio-user@sbates-fork` and
`ubuntu-rocm-ernic@sbates-fork` layer on this variant via `base_variant`;
`ubuntu-spdk-libvfio-user@sbates-fork` pins the same SHA in its submodule; and
`ubuntu-rocm-rocjitsu@sbates-fork` redirects the `FetchContent` in upstream
ROCm's cmake to it. All five must agree — `scripts/version-scrub.sh` warns when
they drift.

## Tags

The tag variant is the abbreviated commit, for example `vfu.8039244`. See the
repository [README](../README.md) for the full tag scheme.
