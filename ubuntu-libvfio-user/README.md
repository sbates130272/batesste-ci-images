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

## Tags

The tag variant is the abbreviated commit, for example `vfu.8039244`. See the
repository [README](../README.md) for the full tag scheme.
