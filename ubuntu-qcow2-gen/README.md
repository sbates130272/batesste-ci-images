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
entry (plus, optionally, one or both of the upstream Ansible playbook names —
see [Two playbook layers](#two-playbook-layers-and-why)). No Dockerfile
change.

`assets/<name>/` is for files a provision script needs *inside* the guest --
patches, generators -- rather than on the builder. When it exists, `build-vm.sh`
copies it to `/tmp/payload` for the provisioning boot, by the same primitive the
mainline kernel `.deb`s already travel by.

[`assets/shared/`](assets/shared/README.md) is **not** a flavour and
`build-vm.sh` never looks for it. The Dockerfile grafts its contents onto named
flavours' payloads, so a file two guests both need -- the `amdgpu-probe` helper,
the RAS vbios patch -- exists once in the repo. A patch applied to one guest and
not the other is a driver that oopses in only one lane, which is the bug that
directory was created in response to. Adding a file there does nothing until it
has a `COPY` in the Dockerfile for each flavour that should receive it.

`provision/<name>.sh` runs inside the guest in its own boot, between cloud-init
and the verification boot, with the changes kept. It is where anything
cloud-init's package list cannot express goes: third-party apt repositories,
patching a source tree, building a DKMS module against the guest's own kernel.

## Two playbook layers, and why

`vm_playbook` is handed to `qemu-tool gen-vm`, so it runs **while the VM is
being created** — before the `kernel_ref` layer and before
`provision/<name>.sh`. That is early enough to be useless for anything that
compiles: a module built there is built against the release's kernel and
installed for one the guest never boots.

`post_playbook` is a second qemu-minimal playbook run **after** both, in a
`PROBE_PERSIST` boot of its own, through the same `probe-guest` primitive
every other layer uses (`PROBE_ANSIBLE=1`). It is for work that needs the
guest as provisioned, and for reaching pins this repo deliberately does not
hold: the qemu-minimal checkout's `requirements.yml` pins rocm-ernic's Ansible
collection to a SHA, and the `ernic-rocjitsu` flavours get the ionic SRQ
series through that collection rather than from a copy vendored here.

The collections are installed by `build-vm.sh` immediately before the run, so
a flavour that sets no `post_playbook` pays nothing for the layer.

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
| `rocjitsu` | `-rocjitsu` | For ROCm/rocm-xio's rocjitsu emulated-GPU jobs. ROCm userspace from the `therock` stream and an `amdgpu-dkms` built against the guest kernel with the KFD atomics patch and the RAS vbios guard applied first, so those jobs stop doing it over SSH. The `amdgpu-probe` helper from `assets/shared/` is installed but never run -- autoload stays blacklisted. Since the probe is a step consumers kept forgetting, a login hint at `/etc/update-motd.d/99-amdgpu-probe` says so at the prompt, but only when there is something to say: a device on the bus with `amdgpu` unloaded, or `amdgpu` loaded with the wrong parameters. It reports, it does not act -- nothing loads the driver for you, because a copy that binds before the vfio-user server is serving costs a reboot to undo. Pinned to `resolute` with `amdgpu_driver_version: 31.60`, the first driver tree that ships gfx1250 firmware; its `amdgpu-dkms` (7.1.9) still builds against the 7.0 kernel the guest boots. Most gfx1250 firmware is baked in as a consequence -- `amdgpu-dkms` depends on `amdgpu-dkms-firmware` -- but `gc_12_1_0_imu.bin` and `ip_discovery.bin` are not, and stay with the consumer's rocjitsu pin. `ROCM_PATH` and `PATH` are set from `/etc/profile.d/rocm.sh`. See [consumers/rocm-xio-rocjitsu.md](consumers/rocm-xio-rocjitsu.md). |
| `ernic-rocjitsu` | `-ernic-rocjitsu` | For ROCm/hipObject's two-device jobs, which need one guest carrying both an emulated ionic RDMA NIC and an emulated gfx1250. Mainline **v7.2.4**, a hard floor rather than a preference: `ionic_rdma` calls `ib_umem_get_va`, which does not exist in 7.0 or 7.1.13. `ionic`/`ionic_rdma` are in-tree there, so the ionic half is the `ionic` flavour's rdma-core stamp and nothing else; the ROCm half is the `rocjitsu` flavour plus three amdgpu patches -- two from `assets/ernic-rocjitsu/`, without which DKMS 7.1.9 does not build against 7.2, and the RAS vbios guard from `assets/shared/` that every rocjitsu guest needs. The firmware gap set is baked in too -- its fixtures are static -- leaving only `ip_discovery.bin` with the consumer's rocjitsu pin, staged into the empty `/lib/firmware/amdgpu` this guest creates for it. Both halves of the **ionic SRQ series** are built in via `post_playbook: vm-ernic-srq.yml` -- rocm-ernic's `patches/srq` as the `ionic-ernic` DKMS modules and its `patches/rdma-core` as an rdma-core in `/usr/local` -- because the in-tree 7.2.4 driver reports `max_srq = 0`, which makes UCX decline `rc_verbs` and fall back to UD. `memlock` is unlimited. **One of the three amdgpu patches changes a security check and has not been reviewed**; see [consumers/hipobject-ernic-rocjitsu.md](consumers/hipobject-ernic-rocjitsu.md). |
| `ernic-rocjitsu-slim` | `-ernic-rocjitsu-slim` | The `ernic-rocjitsu` guest with everything a *runtime* consumer cannot use taken back out, for a lane that boots a prebuilt binary against the two emulated devices rather than building inside the guest. Same kernel, same patched `amdgpu`, same firmware, same ionic half including the SRQ stack -- it is built by that flavour's own provision script (`provision_flavour`) and the same `post_playbook`, so the patches exist in one place and cannot drift. `trim/slim.sh` then removes the toolchain, the kernel headers, the `/usr/src/amdgpu-*` DKMS source, the release's unused kernel, `linux-firmware`, ROCm's LLVM and headers, snapd, docs and every cache -- asserting on the way out that the SRQ modules and the `/usr/local` provider survived -- and finishes with `fstrim`; the build compacts the image afterwards. **Nothing can be compiled in this guest, and cloud-init is disabled** -- no seed ISO, no key injection at launch. `/etc/slim-trim.json` records what went. |

## Trimmed flavours

A flavour that sets `trim` in `images.yml` runs `trim/<file>` in a
`PROBE_PERSIST` boot after provisioning and before the verification boot, so
the checks see what ships and a trim that breaks the guest fails the build
rather than a consumer's job. Two consequences worth knowing:

- `build-vm.sh` **skips the package-presence assertion** for a trimmed
  flavour. One of these installs a package manifest in order to build with it
  and then purges most of it, so the assertion is guaranteed false. Its
  `checks/<flavour>.sh` is what asserts the guest's contents instead, and it
  has to carry negative assertions -- "no gcc", "one kernel", a ceiling on
  used space -- or a trim step that silently stops working ships a fat guest
  under a slim name with every other check still green.
- `probe-guest.sh` attaches the disk with `discard=unmap`, so the trim's
  `fstrim` reaches the qcow2; `build-vm.sh` then rewrites the image with
  `qemu-img convert` to drop the slack. Uncompressed deliberately -- `-c`
  would trade boot speed for payload size, which is the wrong way round here.

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
