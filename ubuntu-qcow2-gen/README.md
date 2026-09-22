# ubuntu-qcow2-gen

Ready-to-boot Ubuntu guest disk images, published as bare qcow2 ORAS
artifacts.

## Overview

One parameterised Dockerfile, one flavour per [`images.yml`](../images.yml)
variant. The build boots a real VM with `qemu-tool gen-vm`, provisions it with
cloud-init packages and optionally an Ansible playbook, verifies it with a
second boot, and exports the result `FROM scratch` -- so a consumer pulls a
bare payload, not the multi-GB QEMU toolchain that produced it.

Adding a guest flavour is `packages/<name>.txt`, `checks/<name>.sh`, an
optional `provision/<name>.sh`, an optional `assets/<name>/` and a `variants:`
entry (plus, optionally, an upstream Ansible playbook name). No Dockerfile
change.

`assets/<name>/` is for files a provision script needs *inside* the guest --
patches, generators -- rather than on the builder. When it exists, `build-vm.sh`
copies it to `/tmp/payload` for the provisioning boot, by the same primitive the
mainline kernel `.deb`s already travel by.

`provision/<name>.sh` runs inside the guest in its own boot, between cloud-init
and the verification boot, with the changes kept. It is where anything
cloud-init's package list cannot express goes: third-party apt repositories,
patching a source tree, building a DKMS module against the guest's own kernel.

## Base image

- [`ubuntu-qemu-libvfio-user`](../ubuntu-qemu-libvfio-user/) -- the builder and
  runner toolchain

`qemu-tool` is reinstalled here from a fresh `qemu-minimal` checkout, so the
CLI and the `ansible/` tree it drives always come from the same commit whatever
the base image pinned. The tree is needed because the playbooks, inventory and
`requirements.yml` live in it, not in the wheel.

## KVM is required

The VM build step runs `--security=insecure`, which is what lets it create and
open `/dev/kvm`. That needs:

```bash
docker buildx build --allow security.insecure ...
```

against a builder started with `--allow-insecure-entitlement=security.insecure`.
`ci-images-tool.py` arranges this from the `entitlement: security.insecure`
field in the spec.

There is no TCG fallback. Emulation is roughly 10x slower, so a missing
`/dev/kvm` fails the build rather than quietly taking hours.

## What is published

`publish: artifact` makes the disk itself the published thing. Each build
pushes:

- the **qcow2**, zstd-compressed, as a bare ORAS artifact under a `-qcow2`
  tag -- pullable with no container runtime
- **`vm-info.json`** and the flavour's **SSH keypair**, attached as an ORAS
  referrer rather than baked into the artifact
- a `FROM scratch` **payload image** carrying `/output`, published alongside
  until the ORAS path has proven itself on a real release

`/output` is also exported to the gitignored `output/<scope>/` on every build.

### Consuming an artifact

```bash
REPO=sbates130272/batesste-ci-images-ubuntu-qcow2-gen-ionic
mkdir vm && cd vm
oras pull "$REPO:latest-qcow2" && zstd -d --long=27 --rm ./*.qcow2.zst
oras pull "$REPO@$(oras discover --format json "$REPO:latest-qcow2" \
    | jq -r '.referrers[0].digest')" && chmod 600 id_rsa
```

Then boot it with [`ubuntu-qemu-libvfio-user`](../ubuntu-qemu-libvfio-user/),
mounting the directory read-write -- QEMU opens the disk rw.

The payload image is consumed with `docker create` + `docker cp`, or with
`COPY --from` in another build. It has no runtime and wants none; the `CMD` is
a path, present only because `docker create` refuses an image with no command
at all.

### vm-info.json

Every flavour ships one. It records what the guest actually is -- release,
architecture, flavour, username and console password, disk path/format/size,
kernel release, whether KVM was used, the package manifest and its digest, the
playbook, and the commits of `qemu`, `libvfio-user` and `qemu-minimal` that
built it. Read it rather than inferring anything from the tag.

### The console password

`PASSWORD` is the guest's console login, not a credential for anything outside
the qcow2, and it is published in `vm-info.json` by design. `images.yml` marks
it `secret: true`, which keeps it out of `build-args` output and therefore out
of CI logs; a BuildKit secret mount would only hide it from the build history
and then ship it in the payload anyway.

## Variants

| Variant | Repository suffix | What differs |
| --- | --- | --- |
| *(default)* | *(none)* | The `basic` flavour: cloud-init packages from `packages/base.txt`, no playbook |
| `ionic` | `-ionic` | For ROCm/rocm-ernic's ionic RDMA jobs. `drivers/infiniband/hw/ionic` merged in Linux 6.18; the toolchain and rdma-core build deps are pre-installed to save those jobs wall-clock, but the ionic-ernic DKMS modules are deliberately **not** built here -- building them from pinned upstream sources is what those jobs exist to test. rdma-core is **not** built: resolute packages 61.0, past the v61 that first shipped `providers/ionic`, so `libionic` comes from the archive with nothing overwritten and nothing held. The guest stamps the version for `ernic_guest_setup` to read -- see [consumers/rocm-ernic-ionic.md](consumers/rocm-ernic-ionic.md). |
| `rocjitsu` | `-rocjitsu` | For ROCm/rocm-xio's rocjitsu emulated-GPU jobs. ROCm userspace from the `therock` stream and an `amdgpu-dkms` built against the guest kernel with the KFD atomics patch applied first, so those jobs stop doing it over SSH. Pinned to `resolute` with `amdgpu_driver_version: 31.60`, the first driver tree that ships gfx1250 firmware; its `amdgpu-dkms` (7.1.9) still builds against the 7.0 kernel the guest boots. Most gfx1250 firmware is baked in as a consequence -- `amdgpu-dkms` depends on `amdgpu-dkms-firmware` -- but `gc_12_1_0_imu.bin` and `ip_discovery.bin` are not, and stay with the consumer's rocjitsu pin. See [consumers/rocm-xio-rocjitsu.md](consumers/rocm-xio-rocjitsu.md). |
| `ernic-rocjitsu` | `-ernic-rocjitsu` | For ROCm/hipObject's two-device jobs, which need one guest carrying both an emulated ionic RDMA NIC and an emulated gfx1250. Mainline **v7.2.4**, a hard floor rather than a preference: `ionic_rdma` calls `ib_umem_get_va`, which does not exist in 7.0 or 7.1.13. `ionic`/`ionic_rdma` are in-tree there, so the ionic half is the `ionic` flavour's rdma-core stamp and nothing else; the ROCm half is the `rocjitsu` flavour plus three amdgpu patches from `assets/ernic-rocjitsu/` without which DKMS 7.1.9 does not build against 7.2. The firmware gap set is baked in too -- its fixtures are static -- leaving only `ip_discovery.bin` with the consumer's rocjitsu pin. **One of the three patches changes a security check and has not been reviewed**; see [consumers/hipobject-ernic-rocjitsu.md](consumers/hipobject-ernic-rocjitsu.md). |

## Tags

The tag variant is the guest release, the flavour and the abbreviated
`qemu-minimal` commit, for example `vm.resolute-ionic-qm.5d68689`; artifact
tags carry a `-qcow2` suffix on top.

That variant does not identify a build on its own -- the flavour's packages,
provision and checks scripts can all change without moving it -- so the fully
specified tag adds the date and this repo's commit in front:
`20260916.g0d300a2-vm.resolute-ionic-qm.5d68689-qcow2`. Pin that one. The bare
variant is rolling and will be replaced by the next build of the same
flavour.

The guest kernel is deliberately absent from the tag -- it is not knowable
until the guest has been built. It is in `vm-info.json` instead. See the
repository [README](../README.md) for the full tag scheme.
