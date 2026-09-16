# Guest image request: ROCm/rocm-ernic, ionic device mode

Status: **published**, most recently as
`20260916.g0d300a2-vm.resolute-ionic-qm.5d68689-qcow2`. Pin that tag rather
than the rolling `vm.resolute-ionic-qm.5d68689-qcow2`: the rolling one moves
with every build of this flavour, and on 2026-09-16 two different guests
published under it within the hour. The guest carries the ionic
verbs provider from the archive and the stamp that says so — see
[rdma-core comes from the archive](#rdma-core-comes-from-the-archive). One
change is wanted in rocm-ernic to make that stamp take effect.

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
dpkg-owned paths under `/usr` with nothing holding it — on a release that
packages the provider anyway. Read literally, the doc invites a rebuild from a
stock cloud image, which does not work.

### Not a consumer

The `ionic-patches` job in `.github/workflows/driver-build.yml` only checks
that the pinned `IONIC_KERNEL_REF` still exists and that the patches still
apply. It deliberately does not build the modules, because hosted runners
lack >= 6.18 headers. It boots no guest and needs no image.

## What the ionic flavour pre-bakes

[`packages/ionic.txt`](../packages/ionic.txt) installs the toolchain, DKMS, the
rdma-core v62 build dependencies, distro rdma-core for `ibv_devinfo`, and
`perftest` for `ib_send_bw` and friends. The mainline kernel, its matching
headers and `linux-modules-<ver>-generic` — which carries `ib_core`,
`ib_uverbs`, `rdma_ucm` and both halves of ionic — come from the `kernel_ref`
layer instead, in a provisioning boot after cloud-init.

No kernel-versioned package is named in the manifest: cloud-init runs before
the mainline kernel exists, so `linux-headers-generic` would pull the release's
7.0 headers and DKMS would build against the wrong tree.

The `ionic-ernic` DKMS modules are deliberately **not** built here — building
them from pinned upstream sources is what the consuming jobs exist to test.

## rdma-core comes from the archive

`ernic_guest_setup` builds rdma-core from source in the guest on every run of
every lane, because `providers/ionic` — the userspace provider that makes the
emulated NIC usable through libibverbs — first shipped upstream in v61 and the
role assumes the distro predates it. On **noble that is true (50.0). On
resolute it is not:** the release packages **61.0-2ubuntu3**, and its stock
`ibverbs-providers` contains

```
/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav59.so
/usr/lib/x86_64-linux-gnu/libionic.so.1.0.61.0
```

— the same provider at the same ABI (`rdmav59`) a 62.0 source build produces.
So this flavour installs nothing and overwrites nothing. No `dpkg`-owned file
under `/usr` is replaced behind its back, and there is therefore nothing to
hold against a later `apt upgrade`. That is a gap the self-hosted
golden image still has, where a source-built rdma-core sits over the packaged
one with `apt-mark showhold` empty.

The ~30 s the source build costs is not the point. The point is that building
it at job time makes every lane of every run depend on the GitHub release CDN,
and on 2026-09-16 that CDN returned HTTP 500 for the 62.0 tarball and failed a
run during provisioning. The archive has no such failure mode.

### The stamp, and what is needed on your side

[`provision/ionic.sh`](../provision/ionic.sh) writes
`/usr/local/share/rocm-ernic/provider.stamp` containing exactly `61.0:none`,
newline included: the version the guest actually has, and `none` because no GDA
patches were applied. It asserts the installed `rdma-core` matches before
writing, so the stamp cannot describe a guest that does not exist.

**This does not skip your build yet.** The role compares the stamp against a
value computed from `ernic_rdma_core_version`, which is pinned at `62.0` and
compared exactly, so `61.0:none` does not match and the lane rebuilds — CDN
dependency included. The ask is one line in
`ansible/roles/ernic_guest_setup/defaults/main.yml`: **set
`ernic_rdma_core_version` to `61.0`.** The role's own hard assert is `>= 61`,
which 61.0 satisfies, and the provider it would build is the one the archive
already installed.

A stamp reading `62.0` over a 61.0 install would buy the skip today without
that change, and is the reason this repo does not do it —
[`checks/ionic.sh`](../checks/ionic.sh) compares the stamp against `dpkg`
rather than against the pin, precisely so a stamp that lies fails this image's
build instead of a consumer's job.

`none`, not a patch hash, is deliberate. The role applies an ionic GDA
direct-verbs series for GPU-passthrough guests and folds a hash of it into the
stamp in place of `none`. Every current lane passes
`ernic_gpu_passthrough=false` and therefore matches; a passthrough run does not
and rebuilds with the patches, which is correct.

If a future `ernic_rdma_core_version` needs to be genuinely newer than what
Ubuntu packages, say so and this flavour can go back to a pinned source build —
but then the holds come with it, and so does the CDN.

One caveat for the consumer side:

- `perftest` is the distro build, so it has no ROCm or CUDA memory support.
  `ib_send_bw --use_rocm` needs perftest compiled against a ROCm the guest does
  not carry; a job wanting GPUDirect numbers must build it in the guest or pull
  a CUDA/ROCm-enabled build from a PPA. Host-memory verbs traffic works as
  packaged. It depends on distro `ibverbs-providers`, and loads providers at
  runtime rather than linking them, so it picks up `libionic` as installed —
  and would equally pick up one from a source rdma-core laid over the top.
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

Note for anyone reaching for the QEMU image instead:
`…-ubuntu-qemu-libvfio-user` no longer carries a guest of any kind. It is the
toolchain — QEMU, `qemu-tool`, ansible-core — and its `/output` is empty. Pull
`…-ubuntu-qcow2-gen-ionic` for the disk and bind-mount it over `/output` if you
want that image to boot it.

## Open

- `vm_playbook` is empty for this flavour, and a `vm-ionic.yml` upstream in
  qemu-minimal — pre-seeding `/opt/ionic-src` — is still an optimisation
  rather than a prerequisite. rdma-core is no longer on that list at all.
- `ernic_rdma_core_version: 61.0` in rocm-ernic, per
  [the stamp](#the-stamp-and-what-is-needed-on-your-side). Until it lands the
  guest is correct and the lanes simply keep rebuilding, as they do today.
- rocm-ernic's brief assumed GitHub-hosted runners have no nested virt. For
  x86 `ubuntu-latest` that is wrong — `/dev/kvm` is present as `root:kvm
  0660`, which is why this repo's workflows carry a udev step. Running QEMU
  in a container needs `--device /dev/kvm` plus that group fix, not nested
  virt. Taking it would stop a 2-vCPU TCG guest eating their time budget.
  Boot mode is a consumer choice and does not gate this image.
