# Guest image request: ROCm/hipObject, ionic RDMA + rocjitsu gfx1250

Status: **flavour in the catalogue, first build not yet published.** Pin a dated
tag when it is; the rolling `vm.resolute-ernic-rocjitsu-qm.<sha>-qcow2` tag moves
with every build of this flavour.

## What was asked for

hipObject's `ernic-rocjitsu-gpu` lane derives its guest at the start of every
run: install a mainline kernel, patch and rebuild `amdgpu-dkms`, generate the
firmware gap set. That costs about fifteen minutes on every run, and it is the
same fifteen minutes every time. The ask was to bake it into a published image
so the lane — and its `ci/ernic/patches/amdgpu/` directory — can drop the derive
step.

The recipe in the request was verified green in CI at hipObject `f193923`,
derived from `ubuntu-qcow2-gen-rocjitsu`
(`20260921.g584b3f9-vm.resolute-rocjitsu-qm.5d68689-qcow2`). This flavour is
that recipe, built from the same sources rather than layered on that image.

| # | Asked for | Landed |
| --- | --- | --- |
| 1 | Mainline **v7.2.4**, the `ionic_rdma` floor | yes — `kernel_ref: v7.2.4` |
| 2 | `ionic` / `ionic_rdma` usable, rocm-ernic's two patches applying unmodified | yes, in-tree from 7.2.4; see [The ionic half](#the-ionic-half) |
| 3 | Three amdgpu patches on top of DKMS 7.1.9 | yes — see [The amdgpu patches](#the-amdgpu-patches) |
| 4 | `--set gap` firmware baked in | yes, except `ip_discovery.bin` — see [Firmware](#firmware) |
| 5 | Login user in `render` and `video` | yes — see [Device node groups](#device-node-groups) |

## Why a third flavour and not a bigger `rocjitsu`

`rocjitsu` is consumed by rocm-xio and `ionic` by rocm-ernic, both against
published tags. Either would have had to move its kernel to 7.2.4 to carry the
other half, and rocm-ernic is pinned to 7.2.3 deliberately. Neither published
consumer moves because of this image.

The cost is duplication: most of
[`provision/ernic-rocjitsu.sh`](../provision/ernic-rocjitsu.sh) is
[`provision/rocjitsu.sh`](../provision/rocjitsu.sh) and
[`provision/ionic.sh`](../provision/ionic.sh) verbatim. That is deliberate — the
kernel and DKMS handling here differs enough from either that factoring the rest
out would buy less than it risks.

## The kernel is a hard floor

`ionic_rdma` calls `ib_umem_get_va`, a `static inline` that exists in 7.2.4 and
does not exist in 7.0 or 7.1.13. A 7.0 guest compiles the floor check and then
fails the build, which is a slow and unclear way to learn this.
[`checks/ernic-rocjitsu.sh`](../checks/ernic-rocjitsu.sh) asserts both the 7.2
version tuple and `ib_umem_get_va` in the installed headers.

It also changes the provisioning order relative to `rocjitsu`. `amdgpu-dkms`'s
postinst builds the **unpatched** source against the 7.2.4 headers, and that
build fails. `/etc/dkms/no-autoinstall-errors` is written before
`apt-get install amdgpu-dkms` so the failure does not leave the package
unconfigured; the real build happens afterwards, from the patched source, for
`$(uname -r)` only. The checks assert `modinfo -n amdgpu` resolves under
`updates/dkms` — i.e. that the thing modprobe picks is the patched build and not
the in-tree driver.

## The amdgpu patches

Three, from `assets/ernic-rocjitsu/patches/amdgpu/`, applied to the
`/usr/src/amdgpu-*` source tree so they survive a later `dkms autoinstall`. They
are carried alongside the KFD atomics patch `rocjitsu` already applies.

| Patch | What it does |
| --- | --- |
| `0001-amdkfd-fail-closed-ptrace-gate-7.2` | **Unreviewed — see below.** Adapts the KFD ptrace gate to the 7.2 signature. |
| `0002-amdkcl-probe-panel-type-separately` | Splits the `drm_display_info.panel_type` kcl probe so 7.2 detects it. |
| `0003-amdgpu-ras-guard-vbios-query` | Guards the RAS vbios query against a null `atom_context`. |

`0001` **changes a security check** and has not had human sign-off. It is
flagged as `TODO(unreviewed)` at the top of
[`patches/amdgpu/README.md`](../assets/ernic-rocjitsu/patches/amdgpu/README.md),
and the guest records `"kfd_ptrace_gate_reviewed": false` in
`/etc/ernic-rocjitsu-guest.json`. Read that field rather than assuming the patch
set is settled. Nothing about this image should be treated as security-reviewed
until it flips.

The checks assert each patch by a marker in the source tree, so a patch silently
failing to apply fails the build rather than the lane.

## Firmware

`--set gap` output is baked in: `gc_12_1_0_imu.bin`, `gc_12_1_0_mes.bin` and
`gc_12_1_0_mes1.bin`, installed into `/lib/firmware/updates/amdgpu` alongside
the real microcode that `amdgpu-dkms-firmware` ships, with the generator's
manifest kept as `rocjitsu-gap-manifest.json`. The provisioning step refuses to
overwrite a packaged filename rather than trusting that it will not collide.

This can be baked in because the gap set is static — the generator's fixtures do not
depend on which rocjitsu build serves the socket. The guest runs it as
`vfio-guest-firmware.py --set gap --generation gfx1250 --no-ip-discovery`, using
the `--generation` mode added for exactly this: there is no rocjitsu config
inside a guest. The script is the single copy in this repo, wired into the build
from `ubuntu-rocm-rocjitsu/` by the Dockerfile, so the fixtures a guest carries
cannot drift from the ones that image's own self-test exercises.

`ip_discovery.bin` is **not** baked in, and is the consumer's job. It comes from
`rj-ip-discovery gfx1250` and must match the rocjitsu pin hipObject runs, not
this image's. `checks/ernic-rocjitsu.sh` asserts it is absent.

Stage it into `/lib/firmware/amdgpu/`, which the image now creates empty with
a README in it. It used not to exist at all, and nothing installs it —
`linux-firmware` is pulled in neither by `linux-image-virtual` nor by the
mainline `.debs` — so the instruction to copy a file there landed in a
missing directory. Without the file, probe ends:

```text
amdgpu 0000:02:00.0: can't load firmware "amdgpu/ip_discovery.bin"
amdgpu 0000:02:00.0: [drm] *ERROR* discovery failed: -2
amdgpu 0000:02:00.0: probe with driver amdgpu failed with error -2
```

**Open:** a working guest was produced by copying the whole 672-file
`/lib/firmware/amdgpu` tree from an earlier image, which is a wider fix than
the one file that failure names, and upstream `linux-firmware` ships no
`ip_discovery.bin` at all. Whether anything else in that tree is actually
needed here has not been established; the directory is created empty and the
question is left open rather than answered by installing half a gigabyte of
microcode for hardware a virtio guest does not have.

## Device node groups

`/dev/kfd` and `/dev/dri/render*` are `root:render` 0660, and the login user was
in neither `render` nor `video`. The symptom is a HIP runtime that enumerates no
agent and a `hipMalloc` returning `hipErrorNoDevice`, three lines below a
perfectly healthy KFD node in the same log.

Fixed in the image: `usermod -aG render,video`. The same change was made to the
`rocjitsu` flavour — see
[`rocm-xio-rocjitsu.md`](rocm-xio-rocjitsu.md#device-node-groups).

Neither device node exists in the probe boot, so the checks assert group
membership, which is the half that is the image's to get right.

## Probe parameters, and the helper that carries them

The image blacklists autoload — `/etc/modprobe.d/amdgpu-blacklist.conf` plus
`modprobe.blacklist=amdgpu` on the kernel cmdline — so nothing loads the driver
for you. The parameters it wants are:

```text
emu_mode=1 discovery=2 fw_load_type=0 ip_block_mask=0x7f vm_update_mode=3 \
    gpu_recovery=0 vramlimit=1024
```

These ship as `/usr/local/bin/amdgpu-probe`, a copy of the helper
qemu-minimal's `vm-rocjitsu.yml` installs. It is **offered, not imposed**:
nothing in the image runs it, the blacklist stands either way, and a consumer
that wants to own the parameters can ignore the file. It is there because the
two values below are easy to get wrong in ways that present as something else,
and because they belong with the driver build rather than with whoever happens
to be calling.

`ip_block_mask` is `0x7f` and not `0x3f`: this DKMS build enumerates an extra
`ras_v1_0` at index 5, which pushes MES to 6. A mask copied from a guest on a
different driver build will silently omit MES.

`vramlimit` is 1024 and not the 256 an earlier draft of this document quoted.
It is not a performance knob — it is the budget ROCr provisions queue scratch
from, and 256 runs scratch-free kernels fine while making a private-segment
dispatch wait forever for an allocation that never arrives. Unrelated to
`vram_aperture_bytes` in the rocjitsu config, which is the BAR window and is
left at upstream's 256 MiB unless a build opts into raising it.

The helper also refuses, loudly, when amdgpu is already resident with the wrong
parameters — `modprobe` returns 0 in that case and discards everything you
passed it, which is the single most expensive way to lose an afternoon here.

**And that state costs a reboot to leave.** A bare `modprobe amdgpu` binds
nothing, and `rmmod amdgpu` then segfaults, so there is no way back to a clean
load in the running guest. Treat `amdgpu-probe` as mandatory rather than as a
convenience: "offered, not imposed" is about the parameters being readable and
overridable, not about the bare `modprobe` being a usable alternative.

## The ionic half

Nothing is installed. resolute packages rdma-core 61.0 and its
`ibverbs-providers` already carries `libionic-rdmav59.so`, so the flavour does
not overwrite dpkg-owned paths and needs no holds. `/usr/local/share/rocm-ernic/provider.stamp`
is written as `61.0:none` — the same stamp the `ionic` flavour writes, in the
format the `ernic_guest_setup` role compares against.

`ionic` and `ionic_rdma` are in-tree in 7.2.4, and rocm-ernic's two patches
apply to it unmodified; the device reaches `PORT_ACTIVE` / `LinkUp`. Building
`ionic-ernic` as a DKMS module stays with the consumer — this image supplies
the kernel, the headers and the toolchain for it.

### SRQ, which the image now carries

The in-tree driver is not sufficient for UCX, and the way it fails names
nothing. Stock 7.2.4 has no SRQ in `drivers/infiniband/hw/ionic`, so
`ibv_devinfo -v` reports `max_srq: 0`; UCX's `rc_verbs` transport is built on
a shared receive queue, so it declines the device —
`failed to query rc_verbs resources: No such device` — and offers only
`ud_verbs`, which has no one-sided RDMA READ/WRITE. Measured on two guests
over one emulated NIC at 1 MiB: UCX 0.064 GB/s on UD against `MORI_IO`'s 0.355
on RC, with `ib_write_bw` reaching 594 MB/s on the same device. The symptom
that reaches a user is "UCX is 5x slower than MORI".

So both halves are built into the image, by `post_playbook: vm-ernic-srq.yml`
in qemu-minimal:

- **Kernel.** rocm-ernic's `patches/srq` — nine patches rebased onto the same
  v7.2.4 the guest boots — built and installed as the `ionic-ernic` DKMS
  package into `updates/dkms`. `ionic.ko` is replaced as well as
  `ionic_rdma.ko`: the LIF-identity patch is in the Ethernet driver.
- **Userspace.** rocm-ernic's `patches/rdma-core` on a pinned master SHA,
  built into `/usr/local`. The archive's `rdma-core` is left installed and
  untouched; `ld.so` searches `/usr/local/lib` first, so the patched provider
  wins at run time and backing it out is removing a prefix.

Neither alone is any use. With only the kernel half the device advertises
`max_srq` and `ibv_create_srq()` returns `EOPNOTSUPP`, because libibverbs
dispatches into a provider with no `create_srq` op — no rdma-core release, nor
`master`, has one ([`linux-rdma/rdma-core#1799`][pr] is still open).

`/etc/ionic-srq-p4.json` records the pins. Three things to know:

1. **Rebuilding `ionic-ernic` here silently removes SRQ** unless you pass
   `fetch-ionic-sources.sh --patches-dir .../patches/srq`. A stock rebuild
   installs under the same DKMS package name and takes the guest back to
   `max_srq: 0` with nothing to show it changed.
2. **The device half is not in this image.** It is the rocm-ernic server
   container; a guest ahead of its server still reports `max_srq: 0`. The
   support merged there at `ernic.3fb74d1`.
3. **Check with `nm`, never `strings`.**
   `strings ionic_rdma.ko | grep -i srq` returns around a dozen hits on a
   module with no SRQ support whatsoever — `IB_USER_VERBS_CMD_CREATE_SRQ`,
   `IONIC_QPT_SRQ`, `rq_tbl_index_srq_id` are BTF enumerator and structure
   field names — and a build carrying no BTF returns zero for the same grep, so the
   two read as a difference that is not there.
   `nm $(modinfo -n ionic_rdma) | grep ionic_create_srq` is the question.

The flavour's checks assert all of this at build time, including the `nm` one.

[pr]: https://github.com/linux-rdma/rdma-core/pull/1799

### Locked memory

`memlock` is unlimited, through `/etc/security/limits.d/99-rdma-memlock.conf`
for PAM logins and `DefaultLimitMEMLOCK=infinity` for units. The release
default is 8192 KB, at which every `ibv_reg_mr()` fails with "Cannot allocate
memory" — reported as a UCX `ud_recv_skb` memory-pool failure, or as NIXL's
`libfabric` plugin saying "Failed to initialize control request pool for rail
0", neither of which mentions `memlock`.

## What is not the image's fault

Two facts about running this guest that no image change can fix:

- **>= 4 vCPUs.** `IONIC_EQ_COUNT_MIN` is 4. A 2-vCPU guest fails in the ionic
  driver, not in anything this image installed. The flavour's own build uses
  `VM_VCPUS=4`, but the consumer's runner configuration is what matters.
- **No warm reboot with the rocjitsu function attached.** The guest cannot be
  rebooted while the vfio-user device is live; cold-boot it instead.

One more, for anyone extending the guest later: `AUTOINSTALL="no"` in
`/etc/dkms/framework.conf` matters if you install another kernel *inside* the
guest. This image writes `/etc/dkms/no-autoinstall-errors`, which keeps a failing
autoinstall from leaving a package unconfigured — it does not stop the
autoinstall from running and does not make it succeed against a kernel the patch
set was not written for.

## What the guest records about itself

`/etc/ernic-rocjitsu-guest.json`, written during provisioning. The fields a
consumer should actually branch on:

| Field | Meaning |
| --- | --- |
| `amdgpu_patches` | `name:sha256[0:16]` for each patch applied, so a drift from the consumer's own copy is visible |
| `kfd_ptrace_gate_reviewed` | `false` — see [The amdgpu patches](#the-amdgpu-patches) |
| `gfx1250_firmware` | `"packaged + generated gap set"` |
| `gfx1250_firmware_generated` | the filenames the gap set contributed |
| `ip_discovery_bin` | `false`; `ip_discovery_bin_source` names where to get it |
| `render_video_groups` | `true` |
| `rdma_driver` | in-tree `ionic_rdma`; `ionic-ernic` is the consumer's DKMS build |

## The slim variant

`ubuntu-qcow2-gen@ernic-rocjitsu-slim` is this image with everything a runtime
consumer cannot use removed: roughly 2-3 GB instead of 9.7, and seconds rather
than most of a minute to reach SSH. It is built from this flavour's own
provision script and assets — `provision_flavour: ernic-rocjitsu` in
`images.yml` — so the patch set, the DKMS build and the firmware gap set are
the same bytes, and then `trim/slim.sh` subtracts.

Use it for a lane that **boots a binary built elsewhere** against the two
emulated devices. Do not use it for this lane: hipObject's `ernic-rocjitsu-gpu`
job builds `ionic-ernic` as a DKMS module inside the guest, and the slim guest
has no compiler, no kernel headers and no DKMS. It also cannot rebuild
`amdgpu`, so do not install a kernel in it.

Two further differences a consumer sees:

- **cloud-init is disabled.** No seed ISO, no userdata, no key injection at
  launch. The baked-in `ubuntu` login and the keypair published beside the
  image are the way in; the netplan written during the fat build is kept, so
  the guest still gets an address.
- **ROCm's LLVM and headers are gone.** The HIP runtime and the device bitcode
  under `${ROCM_PATH}/amdgcn` are present; `hipcc` is not.

`/etc/slim-trim.json` records what the trim removed, including the before and
after footprint. Read that rather than inferring capability from the flavour
name.

## Publishing contract

Unchanged from the other flavours: a `FROM scratch` payload whose `/output`
carries the qcow2, `id_rsa`, `id_rsa.pub` and `vm-info.json`. `vm-info.json` is
`schema_version: 5` — the addition over 4 is `provisioning.assets`, naming the
per-flavour asset directory copied into the provisioning boot (`ernic-rocjitsu`
here, `none` for flavours that carry none).

Consume an explicit dated tag, never `:latest`.

## Open

- **`0001` has not been reviewed.** It is the one item on this list that should
  block treating the image as settled.
- The image cannot be end-to-end tested in the build. The probe boot has neither
  an ionic device nor a vfio-user GPU, so it asserts that everything is
  installed and patched as promised, not that either device comes up.
  Qualification is a boot under both stacks.
- The firmware gap set is baked at the generator's current fixtures. If
  upstream rocjitsu changes them, this image has to be rebuilt — the guest
  cannot detect that on its own, and `rocjitsu-gap-manifest.json` is the record
  of what it was built with.
