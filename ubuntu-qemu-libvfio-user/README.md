# ubuntu-qemu-libvfio-user

The QEMU builder/runner toolchain: QEMU built with vfio-user and slirp, the
`qemu-tool` CLI, `ansible-core`, the Docker CLI, `oras` and `zstd`.

## Overview

This is the image CI jobs run *in* when they need to boot a VM. It carries
everything required to build, provision and run a guest, but no guest of its
own -- `/output` ships empty. Guest disks are built by
[`ubuntu-qcow2-gen`](../ubuntu-qcow2-gen/), one repository per flavour, and
supplied at run time.

Keeping the toolchain and the guests apart means a new guest flavour does not
rebuild the multi-GB QEMU layer, and a QEMU bump does not invalidate every
guest.

## Base image

- [`ubuntu-libvfio-user`](../ubuntu-libvfio-user/)

## What is installed

- **QEMU** under `/opt/qemu`, built `--target-list=x86_64-softmmu
  --enable-slirp`, and on `PATH`
- **`qemu-tool`** in its own venv at `/opt/qemu-tool`, symlinked into
  `/usr/local/bin`. Guest builds and boots go through its `gen-vm` and `run-vm`
  subcommands; the standalone bash scripts of those names are obsolete and
  nothing may call them.
- **`ansible-core`**, installed with pipx into `/usr/local/bin` so both
  `ansible-playbook` and `ansible-galaxy` are on `PATH` for
  `qemu-tool --ansible-playbook`
- **Docker CLI, buildx and compose plugins** -- the CLI only, no engine.
  `qemu-tool compose` shells out to `docker compose`, and jobs running in this
  image drive the host daemon over a bind-mounted `/var/run/docker.sock`.
- **`oras` and `zstd`**, pinned by version and SHA256, for pulling published
  guest artifacts without installing them on the critical path of every job
- `cloud-image-utils`, `qemu-utils`, `openssh-client`, `jq`

The `qemu-minimal` checkout `qemu-tool` was installed from is deleted after
install. `ubuntu-qcow2-gen` re-clones it, `git clone` refuses a non-empty
target, and `entrypoint.sh` accepts a guest mounted at
`/build/qemu-minimal/images`.

## Usage

Fetch a guest and boot it. The disk is a bare OCI artifact, so no container
runtime is needed to pull one:

```bash
REPO=sbates130272/batesste-ci-images-ubuntu-qcow2-gen-ionic
mkdir vm && cd vm
oras pull "$REPO:latest-qcow2" && zstd -d --long=27 --rm ./*.qcow2.zst
# vm-info.json and the SSH keypair ride in a referrer, not in the artifact:
oras pull "$REPO@$(oras discover --format json "$REPO:latest-qcow2" \
    | jq -r '.referrers[0].digest')" && chmod 600 id_rsa
docker run -v "$PWD:/output" ...   # rw: QEMU opens the disk rw
```

The mount must be read-write. `entrypoint.sh` also accepts a guest under
`/build/qemu-minimal/images`.

### Defaults

`USERNAME=batesste`, `QEMU_PATH=/opt/qemu/bin/`, `SSH_PORT=2222`, `VCPUS=2`,
`VMEM=4096`. Override them in the environment.

## Variants

| Variant | Repository suffix | What differs |
| --- | --- | --- |
| *(default)* | *(none)* | Upstream QEMU at the pinned tag |
| `sbates-fork` | `-sbates-fork` | Built from a pinned commit of the `sbates130272` fork, carrying the PCI MMIO bridge work that is not yet upstream |

The fork branch is rebased and force-pushed as the series is reworked, so the
variant pins a SHA rather than the branch. Bumping it means editing
`qemu_commit` in [images.yml](../images.yml); the branch it came from is
recorded in `qemu_branch` and in the `…qemu.branch` label.

## Tags

The tag variant combines the QEMU version and the libvfio-user commit, for
example `qemu11.1.1-vfu.8039244`. A fork build names the commit instead of a
version, for example `qemu.7794baa-vfu.8039244` -- note that this names the
pinned QEMU commit, so pinning the fork to a new SHA changes the tag.

The fully specified tag prefixes the date and this repo's commit,
`20260916.g0d300a2-qemu11.1.1-vfu.8039244`, and is the one to pin. See the
repository [README](../README.md) for the full tag scheme.
