# ubuntu-rocm-ernic

[ROCm/rocm-ernic](https://github.com/ROCm/rocm-ernic) built from source: an
emulated RDMA NIC served over vfio-user.

## Overview

`rocm-ernic` emulates an RDMA-capable NIC in a process outside the VMM and
offers it to a guest over a vfio-user socket. It is the device *provider*;
[`ubuntu-qemu-libvfio-user`](../ubuntu-qemu-libvfio-user/) is the consumer, and
the two share a libvfio-user layer so they cannot disagree about the protocol
they speak.

## Base image

- [`ubuntu-libvfio-user`](../ubuntu-libvfio-user/) -- libvfio-user is already
  built and installed under `/usr/local` there, pinned to the same commit this
  image builds against

## What is installed

- `rocm-ernic`, built with CMake/Ninja and installed under `/usr/local`
- its RDMA userspace headers: `libibverbs-dev`, `librdmacm-dev`
- `/usr/local/share/rocm-ernic/s3_rdma_client.c`, the guest half of the S3
  backend, as source

`-DERNIC_WERROR=OFF`: upstream is not warning-clean against this toolchain, and
a new compiler warning should not break an unrelated image build.

The resolved commit is recorded at `/usr/local/share/rocm-ernic-commit.txt`,
alongside `/usr/local/share/libvfio-user-commit.txt` from the base image.

The client source ships because upstream wrote it to be copied into a guest and
built there on its own (`cc -O2 -Wall -Wextra -o s3_rdma_client
s3_rdma_client.c -libverbs`), and taking it out of this image is what keeps
client and server on one commit — they disagree about the `x-amz-rdma-token`
layout otherwise, and that failure is a transfer that goes nowhere.
`scripts/perf-harness.sh` copies it out of here to measure S3 over RDMA.

## Usage

The default command prints the CLI help:

```bash
docker run --rm \
  docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-ernic:latest
```

To serve a device, share a directory for the socket with whatever runs the
guest:

```bash
docker run --rm -v /run/ernic:/run/ernic \
  docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-ernic:latest \
  rocm-ernic --vfio-socket /run/ernic/ernic.sock ...
```

## Pins

`rocm_ernic_commit` in [`images.yml`](../images.yml), and
`libvfio_user_commit` inherited from `defaults.vars`. Both appear in the tag,
so a build that differs only in a pin gets its own tag.

## Tags

The tag variant is the two abbreviated commits, for example
`ernic.0b48aa1-vfu.8039244`. See the repository [README](../README.md) for the
full tag scheme.
