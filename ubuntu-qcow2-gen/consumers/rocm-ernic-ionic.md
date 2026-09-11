# Guest image request: ROCm/rocm-ernic, ionic device mode

Status: **blocked on this repo** — `ubuntu-qcow2-gen@ionic` exists and its
packages and checks are in place, but no image has been published yet.

## What is needed

A guest qcow2 whose kernel is **>= 6.18**, because
`drivers/infiniband/hw/ionic` merged in 6.18. On an older guest the Ethernet
half of the driver builds and the RDMA half does not, which fails late and
unclearly.

6.18 is the floor and not the target. `ionic-ernic` v7.2.4 calls
`ib_umem_get_va`, added after 7.0, so a 7.0 guest compiles the floor check and
then fails the DKMS build. The flavour therefore pins **mainline v7.2.3** —
`kernel_ref: v7.2.3` in `images.yml` — on the catalogue-default `resolute`
userspace.

The kernel is not a guess: 7.2.3, build stamp `202609030700`, is what
rocm-ernic's self-hosted golden image is already running and passing on. It was
installed there by hand and recorded nowhere, which is why the two self-hosted
guests have since drifted onto different kernels. Pinning it in the catalogue
is the point of this flavour.

The distro release does not constrain the kernel — Ubuntu's mainline builds are
published once per version, not per release. No release ships 7.2.3 (resolute's
GA kernel is 7.0.0-31), so `kernel_ref` installs it on top either way, and the
release only decides how painful that is:

| | noble (24.04) | resolute (26.04) |
| --- | --- | --- |
| `run-parts` with two directories | debianutils 5.17, fails `missing operand` | 5.23.2, works |
| gcc for 7.x headers | 13, needs `ppa:ubuntu-toolchain-r/test` for gcc-15 | 15 in the archive |

The golden image got past both by hand: a 370-byte package-less `run-parts`
shim at `/usr/local/bin/run-parts`, and the toolchain PPA. Neither is visible
to `dpkg -V`, and neither is reproducible from anything written down.
`release: resolute` removes both, which is why this flavour does not pin its
own release.

[`checks/ionic.sh`](../checks/ionic.sh) asserts both the 6.18 tuple floor and
the presence of `ib_umem_get_va` in the installed headers, and `build-vm.sh`
fails the build if the guest boots a kernel other than the pinned one.

## Consumers

Both are the *same* guest, and the second asserts on what the first built —
not two independent floors.

1. **Golden backing image.** `ernic_vm_release: noble` in
   `ansible/group_vars/all.yml`, consumed as `RELEASE:` when
   `ansible/playbooks/vm-create.yml` creates
   `<vm_name_base>-backing.qcow2`.
2. **`driver_ionic.yml`** in the `ernic_guest_setup` role asserts
   `ansible_kernel.split('-')[0] is version(ernic_ionic_min_kernel, '>=')`
   with `ernic_ionic_min_kernel: "6.18"`. This runs against the guest built
   in (1).

`ernic_vm_release` becomes moot once this image is consumed instead of built
locally; until then it should move to `resolute` for the reasons above.

`ansible/roles/ernic_image_prep/tasks/kernel_mainline.yml` (commit `e062ac4`,
on `feat/ionic-default` only) does fetch the mainline `.deb`s and verifies them
against `CHECKSUMS`, which is better than this repo does. But it carries none
of the hand-workarounds the golden image needed, and installs with `apt-get
install ./*.deb`, so **it fails on a clean noble** at the same
`run-parts: missing operand`. It has only ever run against a host that already
had the shim.

The assert itself is correct as written: `is version` compares properly, so
`7.2.3 >= 6.18` passes, and `.split('-')[0]` strips the `-<abi>-generic`
suffix. It does **not** need changing.

`docs/ionic.rst` does need changing: it says nothing about the guest is
bespoke apart from a two-line device-ID patch. The working guest runs a
hand-installed mainline kernel behind a hand-written `run-parts` shim, gcc-15
from a third-party PPA, and a source-built rdma-core 62.0 overwriting
dpkg-owned paths under `/usr` with nothing holding it. Read literally, the doc
invites a rebuild from a stock cloud image, which does not work.

### Not a consumer

The `ionic-patches` job in `.github/workflows/driver-build.yml` only checks
that the pinned `IONIC_KERNEL_REF` still exists and that the patches still
apply. It deliberately does not build the modules, because hosted runners
lack >= 6.18 headers. It boots no guest and needs no image.

## What the ionic flavour pre-bakes

[`packages/ionic.txt`](../packages/ionic.txt) installs the toolchain, DKMS, the
rdma-core v62 build dependencies, and distro rdma-core for `ibv_devinfo`. The
mainline kernel, its matching headers and `linux-modules-<ver>-generic` — which
carries `ib_core`, `ib_uverbs`, `rdma_ucm` and both halves of ionic — come from
the `kernel_ref` layer instead, in a provisioning boot after cloud-init.

No kernel-versioned package is named in the manifest: cloud-init runs before
the mainline kernel exists, so `linux-headers-generic` would pull the release's
7.0 headers and DKMS would build against the wrong tree.

The `ionic-ernic` DKMS modules are deliberately **not** built here — building
them from pinned upstream sources is what the consuming jobs exist to test.

Two caveats for the consumer side:

- 26.04's apt `rdma-core` still predates `providers/ionic` (upstream v61), so a
  job needing `libionic*.so` must still build rdma-core from source over the
  top. That build overwrites dpkg-owned files under `/usr`, so hold or
  remove apt `rdma-core` / `libibverbs-dev` / `ibverbs-utils` afterwards, or a
  later `apt upgrade` reverts it. On the existing self-hosted guests nothing
  holds them today — `apt-mark showhold` is empty.
- `IONIC_KERNEL_REF` is pinned at `v7.2.4` there and `kernel_ref` at `v7.2.3`
  here: one point release apart, which is the skew already proven to work.
  Nothing asserts they stay compatible beyond `checks/ionic.sh`, so keep the
  two moving together — a kernel below 7.2 fails on `ib_umem_get_va`.

## Acceptance

1. `./ci-images-tool.py build ubuntu-qcow2-gen@ionic` passes, including the
   probe boot running `checks/ionic.sh`.
2. `vm-info.json` reports `flavour: ionic`, `release: resolute`,
   `kernel_release: 7.2.3-070203-generic` and a `kernel_debs` list carrying the
   build stamp.
3. The image is published, and rocm-ernic consumes it instead of building a
   golden image of its own.

## Open

- `vm_playbook` is empty for this flavour. A `vm-ionic.yml` upstream in
  qemu-minimal — source-building rdma-core 62.0 and pre-seeding
  `/opt/ionic-src` — is an optimisation, not a prerequisite. Guest
  provisioning is owned upstream so it stays shared with the non-container
  `qemu-tool` workflows.
- rocm-ernic's brief assumed GitHub-hosted runners have no nested virt. For
  x86 `ubuntu-latest` that is wrong — `/dev/kvm` is present as `root:kvm
  0660`, which is why this repo's workflows carry a udev step. Running QEMU
  in a container needs `--device /dev/kvm` plus that group fix, not nested
  virt. Taking it would stop a 2-vCPU TCG guest eating their time budget.
  Boot mode is a consumer choice and does not gate this image.
