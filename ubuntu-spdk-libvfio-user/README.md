# ubuntu-spdk-libvfio-user

[SPDK](https://spdk.io)'s NVMe-oF target built from source and configured to
serve an NVMe controller over vfio-user, with both LBA and Key Value
namespaces.

## Overview

SPDK emulates an NVMe controller in a process outside the VMM and offers it to
a guest over a vfio-user socket, using its existing NVMe-oF target with
vfio-user as a shared-memory transport. It is the device *provider*;
[`ubuntu-qemu-libvfio-user`](../ubuntu-qemu-libvfio-user/) is the consumer.

It completes the set of device servers in this repo:
[`ubuntu-rocm-ernic`](../ubuntu-rocm-ernic/) serves an RDMA NIC,
[`ubuntu-rocm-rocjitsu`](../ubuntu-rocm-rocjitsu/) serves a GPU, and this serves
storage.

## Base image

- [`ubuntu-base`](../ubuntu-base/) — **not** `ubuntu-libvfio-user`.

SPDK's vfio-user target only builds against libvfio-user's own `spdk` branch,
which SPDK carries as a submodule. This repo's shared `libvfio_user_commit`
tracks the qemu-project tree that QEMU and `rocm-ernic` link against, so
pinning both from `images.yml` would mean a bump to one breaking the other.
SPDK therefore uses its submodule. That SHA is only known once the clone
happens, so it cannot be an `images.yml` pin or a label; it is recorded inside
the image at `/usr/local/share/libvfio-user-commit.txt` and in
`/usr/local/share/spdk-build.json` instead. For the same reason the tag is
`spdk.<sha>` alone rather than the two-pin form `rocm-ernic` uses.

## Why a fork

The default build is [`mmgaggle/spdk`](https://github.com/mmgaggle/spdk) on
`rados-nkv`, not `spdk/spdk`, and that is not a temporary embarrassment.
Upstream SPDK v26.05 added the NVMe Key Value command set to the *initiator*
only (`include/spdk/nvme_kv.h`). The target-side `kvdev` layer,
`module/kvdev/` and `nvmf_subsystem_add_kv_ns` exist nowhere upstream, so no
`spdk/spdk` ref can serve a KV namespace to a guest and there is no upstream
variant worth publishing. This is the tree
[ROCm/rocm-xio PR #183](https://github.com/ROCm/rocm-xio/pull/183) proved the
KV path on.

Retire the fork when that work lands upstream.

## What is installed

- SPDK at `/opt/spdk`, built `--with-vfio-user --without-nvme-cuse`. The target
  binary is symlinked to `/usr/local/bin/nvmf_tgt` and the RPC client to
  `/usr/local/bin/rpc.py`.
- Provenance at `/usr/local/share/spdk-commit.txt`,
  `/usr/local/share/libvfio-user-commit.txt` and
  `/usr/local/share/spdk-build.json`.

`--without-nvme-cuse`: the CUSE character devices need `/dev/fuse` and a
privileged container, and nothing here drives an NVMe controller from the host
side.

**No Ceph, deliberately.** The image builds without `--with-rbd`, so
`CONFIG_RBD` is off. `module/kvdev/Makefile` keeps `mem` in `DIRS-y`
unconditionally and gates only `rados` on that flag, so the KV command set still
works — backed by memory — while ~1 GB of Ceph daemons stays out of the image.
The Ceph-backed KV reproduction case lives in rocm-xio PR #183.

A build-time probe starts the target, creates one memory-backed LBA namespace,
one file-backed LBA namespace and one KV namespace, and asserts the vfio-user
socket appears — so a fork whose RPC names have moved fails the image build
rather than a deployment.

## Usage

The default command serves a controller and blocks:

```bash
docker run --rm \
  -v /tmp/vfio-sockets:/tmp/vfio-sockets \
  docker.io/sbates130272/batesste-ci-images-ubuntu-spdk-libvfio-user:latest
```

That yields one 512 MiB memory-backed LBA namespace and one memory-backed KV
namespace on `/tmp/vfio-sockets/nvme/cntrl`. Anything else is
`NVME_NAMESPACES`:

```bash
docker run --rm \
  -v /tmp/vfio-sockets:/tmp/vfio-sockets \
  -v /srv/nvme:/data \
  -e NVME_NAMESPACES='lba:malloc:256M,lba:aio:/data/ns2.img,kv:mem' \
  docker.io/sbates130272/batesste-ci-images-ubuntu-spdk-libvfio-user:latest
```

Any argument other than `--probe` is run instead of the target, so the image
doubles as its own client:

```bash
docker exec <container> rpc.py nvmf_get_subsystems
docker exec <container> rpc.py kvdev_mem_get_entry KvMem0 mykey
```

### Namespace grammar

`NVME_NAMESPACES` is a comma-separated list of `kind:backing[:args]`. All of
them land in one subsystem, so a single controller can present both command
sets — `lib/nvmf/nvmf_rpc.c` branches on whether a namespace has a `kvdev`.

| Spec | Backing | Notes |
| --- | --- | --- |
| `lba:malloc:<size>[:<blocklen>]` | memory | size as `512M` / `2G`; block size defaults to 4096 |
| `lba:aio:<path>[:<blocklen>]` | file | created sparsely at `SPDK_AIO_DEFAULT_SIZE` (1G) if absent |
| `kv:mem[:<max_value_len>[:<max_num_keys>]]` | memory | |

**There is no file-backed KV namespace.** The fork's only KV backends are
`kvdev_mem` (memory) and `kvdev_rados` (Ceph), and this image builds without
the latter. So "memory and files" is available on the LBA side and memory-only
on the KV side; `kv:` with any other backing fails with a message saying so.

### Environment

| Var | Default | Meaning |
| --- | --- | --- |
| `NVME_NAMESPACES` | `lba:malloc:512M,kv:mem` | see above |
| `NQN` | `nqn.2019-07.io.spdk:cnode1` | subsystem NQN |
| `VFIO_USER_SOCKET_DIR` | `/tmp/vfio-sockets/nvme` | socket is `<dir>/cntrl` |
| `SPDK_SERIAL` | `SPDKVFU01` | controller serial |
| `SPDK_CPUMASK` | `0x1` | `nvmf_tgt -m` |
| `SPDK_HUGE` | `auto` | `auto`, `on` or `off` |
| `SPDK_MEM_SIZE` | `1024` | `-s`, in MiB, when hugepages are off |
| `SPDK_AIO_DEFAULT_SIZE` | `1G` | size of an `lba:aio` file created on demand |
| `SPDK_JSON_CONFIG` | unset | an SPDK JSON config to use instead of all of the above |

`SPDK_JSON_CONFIG` bypasses generation entirely and execs
`nvmf_tgt --json <file>`, for a caller who wants full SPDK expressiveness.

### Hugepages

SPDK normally allocates from hugepages, which a container does not get unless
it is privileged or `/dev/hugepages` is mounted with pages already reserved.
`SPDK_HUGE=auto` detects this and falls back to `--no-huge -s $SPDK_MEM_SIZE`,
which is what makes a plain `docker run` work. The device still reaches guest
RAM either way: that memory arrives as an mmap-able descriptor over the
vfio-user socket, not from SPDK's own pool.

To use real hugepages instead:

```bash
docker run --rm --privileged \
  -v /dev/hugepages:/dev/hugepages \
  -v /tmp/vfio-sockets:/tmp/vfio-sockets \
  -e SPDK_HUGE=on \
  docker.io/sbates130272/batesste-ci-images-ubuntu-spdk-libvfio-user:latest
```

## Attaching a guest

`ubuntu-qemu-libvfio-user`'s entrypoint takes a `VFIO_USER_SOCKET` and sets up
the `memory-backend-memfd,share=on` the device needs to reach guest RAM, so no
change to that image is required:

```bash
docker run --rm \
  -v /tmp/vfio-sockets:/tmp/vfio-sockets \
  -v "$PWD/vm:/output" \
  -e VM_NAME=batesste-ci-vm \
  -e VFIO_USER_SOCKET=/tmp/vfio-sockets/nvme/cntrl \
  -p 2222:2222 \
  docker.io/sbates130272/batesste-ci-images-ubuntu-qemu-libvfio-user:latest
```

In the guest, `nvme list` shows an "SPDK bdev Controller" and
`nvme list-ns --csi` distinguishes the LBA and KV namespaces.

That entrypoint takes one socket, so this and a rocjitsu GPU cannot currently
be attached to the same guest through it.

## Pins

`spdk_repo`, `spdk_branch` and `spdk_commit` in [`images.yml`](../images.yml).
libvfio-user is not pinned here — it comes from SPDK's submodule, as above.

## Tags

The tag variant is the abbreviated SPDK commit, for example `spdk.18d1d8d`.
See the repository [README](../README.md) for the full tag scheme.
