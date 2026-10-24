# ubuntu-rocm-rocjitsu

rocjitsu serving an emulated AMD GPU over vfio-user, so a guest can drive a
gfx1250 compute device with no physical GPU attached.

## Overview

rocjitsu lives in the `emulation/rocjitsu` tree of
[ROCm/rocm-systems](https://github.com/ROCm/rocm-systems). Built here with
`ROCJITSU_ENABLE_VFIO=ON`, it exposes the emulated device on a vfio-user
socket; a QEMU guest -- see
[`ubuntu-qemu-libvfio-user`](../ubuntu-qemu-libvfio-user/) -- attaches to that
socket and sees a GPU.

Unlike the other vfio-user images here, this one builds `FROM ubuntu-base` and
uses the libvfio-user that rocjitsu's own
`cmake/rj_libvfio_user.cmake` fetches and pins, not the shared layer. The
transport has to be the one upstream tested against.

## Base image

- [`ubuntu-base`](../ubuntu-base/)

## What is installed

- `rocjitsu` and its tooling under `/usr/local`, built with gcc/g++-14
- **`rj-ip-discovery`** -- generates the `ip_discovery.bin` that
  `amdgpu.discovery=2` reads instead of polling BAR registers. Without it the
  guest driver stalls in `gfx_v12_1_hw_init`. Upstream builds it but ships no
  `install()` rule, so it is lifted out of the build tree by hand.
- **`run-vfio-guest.py`** -- upstream's harness for booting a prepared guest
  against the vfio-user socket
- **`vfio_guest_firmware.py`** -- generates what the guest's own driver release
  does not ship: `gc_12_1_0_imu.bin`, `ip_discovery.bin`, and a manifest naming
  every file. `--set full` emits the whole stub set instead, for a guest on an
  `amdgpu` release older than 31.60. See [Firmware](#firmware) below.
- the config profiles under `/usr/local/share/rocjitsu/configs`
- **`/usr/local/share/rocjitsu/rocjitsu-scratch-repro.hip`** -- a standalone
  reproducer for the dynamic-scratch path. Staged, not built: there is no
  `hipcc` here and no GPU to run it on. Copy it into the guest.
- `/usr/local/share/rocjitsu-build.json`, recording the repo, branch, commit,
  the libvfio-user and json-c tags built against, and the guest tools shipped.
  The dependency tags are read out of `cmake/rj_libvfio_user.cmake` at build
  time rather than restated, so an upstream bump cannot leave them lying.
  `local_patches` is present and empty -- see [Local patches](#local-patches).

  Three fields describe libvfio-user, because the cmake states what upstream
  *declares* and the `sbates-fork` variant builds something else:
  `libvfio_user_upstream_tag` is the declared pin (`v0.8`),
  `libvfio_user_tag` is what was actually built, and `libvfio_user_source` is
  `rocjitsu-cmake` on a default build or the fork's repository URL on the
  variant. On a default build the first two are equal.

## Local patches

None. The tree is built unmodified.

This image carried a five-patch series until 2026-09-18, without which the
served device could not boot a guest (`Timeout waiting for VM flush ACK!`,
then `ring sdma0.0 timeout`) let alone run a kernel needing private memory.
All five are in `develop` now, by way of `bdc4aea25` and `d5927b503`: the GART
root validator masks the PDE flag bits the driver sets, the GART translator
passes out-of-aperture addresses through to VRAM, and the command processor has
a dynamic-scratch request/reclaim state machine that is a strict superset of
what the local patch did. `git log -- ubuntu-rocm-rocjitsu/patches/` has the
series and the reasoning behind each one.

Two consequences:

- **The pin tracks the branch head again.** `scripts/version-scrub.sh` bumps
  `rocjitsu_commit` on every `develop` bump. The freeze it applies while
  `patches/` is non-empty is dormant, not deleted; re-adding a patch
  re-engages it.
- **A bump is still not free.** Nothing upstream tests this path: no CI
  anywhere enables `ROCJITSU_ENABLE_VFIO`, and the only registered vfio tests
  are the launcher against a fake server and a compile-time `#ifdef` check. A
  refactor on `develop` can take those three behaviours away with every
  upstream check green. The Dockerfile asserts each by name against the
  checked-out source, so that failure lands in `docker build` rather than in a
  guest that hangs.

### Build-time verification

Five checks run in the image build, so a broken stack fails where the output
is legible rather than as a hung guest:

1. `rocjitsu` is started against the pinned config and must log `vfu: serving`
   with a live socket
2. `rj-ip-discovery gfx1250` must produce a non-empty artefact -- a guest given
   an empty `ip_discovery.bin` hangs in `hw_init` instead of failing cleanly
3. `run-vfio-guest.py --help` must run, which catches a Python the base image
   cannot import it under
4. `vfio_guest_firmware.py` must emit every file its own manifest names, in
   both sets; the default set must carry `gc_12_1_0_imu.bin` and must *not*
   carry any name a driver release ships, since a sentinel stub written over
   real microcode is strictly worse than nothing; each alias must carry its
   source's bytes; and a config it has no firmware for must be refused rather
   than served gfx1250 stubs
5. the three upstream behaviours listed above must be present in the source
   tree -- `kPageTableRootFlags` in `gpu_vm.cpp`,
   `RoutesAddressesOutsideTheGartApertureToVram` in `gpu_pci_device_test.cpp`,
   `request_dynamic_scratch` in `command_processor.cpp` -- and
   `local_patches` must be empty

Check 5 greps source, which is crude, but these are behaviours with no runtime
probe short of booting a guest. None of the five exercise what they do. See
[Verifying an image](#verifying-an-image).

## Firmware

Upstream removed the stub generator when `emulation/rocjitsu/docs/qemu-vfio.md`
moved to "use firmware files from the same public driver/firmware release as
the guest's `amdgpu.ko`", and from `amdgpu` 31.60 that release exists.
`amdgpu-dkms-firmware` ships real `gc_12_1_0_mec.bin`, `gc_12_1_0_mec_1.bin`,
`gc_12_1_0_rlc.bin`, `gc_12_1_0_rlc_1.bin`, `gc_12_1_0_uni_mes.bin` and
`sdma_7_1_0.bin` into `/lib/firmware/updates/amdgpu`, and `amdgpu-dkms`
*depends* on it -- so a guest that has the driver already has them, with no
copying step and no version skew to manage. (31.50 shipped 683 files and not
one of these, which is why this image used to synthesize everything.)

Two files the driver still opens are in no package:

- **`gc_12_1_0_imu.bin`** -- `AMDGPU_UCODE_REQUIRED` whenever `fw_load_type` is
  not `AMDGPU_FW_LOAD_PSP`, which is exactly the `amdgpu.fw_load_type=0` that
  doc prescribes. Its error propagates fatally out of
  `gfx_v12_1_init_microcode`, and no `amdgpu_emu_mode` guard bypasses it.
- **`ip_discovery.bin`** -- generated by `rj-ip-discovery`, not packaged
  anywhere.

That gap is what one call produces:

```bash
docker run --rm -v "$PWD/fw:/out" "$IMAGE" \
    python3 /usr/local/bin/vfio_guest_firmware.py --output /out
```

That writes `gc_12_1_0_imu.bin`, the two MES aliases, `ip_discovery.bin` and a
`manifest.json` naming them:

```json
{
  "generation": "gfx1250",
  "gfx_target_version": 120500,
  "config": "gfx1250_mi455x.json",
  "set": "gap",
  "packaged_by_driver_release": ["gc_12_1_0_mec.bin", "..."],
  "files": ["gc_12_1_0_imu.bin", "..."]
}
```

Copy the files into the guest's `/lib/firmware/amdgpu/` and assert against the
manifest rather than a filename of your own -- then a firmware file added here
needs no change on the consuming side. Nothing in the default set collides with
a packaged name, so it can be copied over a provisioned guest without
overwriting real microcode with a sentinel stub.

### The full set

For a guest on an `amdgpu` release older than 31.60, `--set full` emits
everything instead: the five upstream fixtures plus `gc_12_1_0_mec_1.bin`,
`gc_12_1_0_rlc.bin` and the two MES aliases. `manifest.json` records which set
was written, and `packaged_by_driver_release` lists what was deliberately left
to the guest -- empty for the full set.

The bare and `_1` spellings of `mec` and `rlc` are both emitted because which
one the driver requests turns on `adev->rev_id`, which `soc_v1_0_set_rev_id`
derives from an NBIO register and the IP-discovery die rev rather than from PCI
config space -- so it is not something the served config states. The packaged
firmware ships both; the full set does too, rather than predicting it.

The 7.1.3 driver also opens `psp_15_0_8_toc_1.bin`, which nothing public
provides and this generator does not emit; the similarly named
`psp_15_0_0_toc.bin` and `psp_15_0_9_toc.bin` are different parts and must not
be substituted.

`ip_discovery.bin` must come from the same rocjitsu commit that serves the
device, which is why it is generated here rather than shipped in a guest disk.

### Which generation

`--config` takes the same config the server takes -- a name under
`ROCJITSU_CONFIG_DIR` or a path -- and the generation is derived from its
`gfx_target_version`, so a caller never names one:

```bash
docker run --rm -v "$PWD/fw:/out" -e ROCJITSU_CONFIG_PATH \
    "$IMAGE" python3 /usr/local/bin/vfio_guest_firmware.py \
    --config gfx1250_mi455x.json --output /out
```

It defaults to `ROCJITSU_CONFIG_PATH`, so a stack that already configures which
config the server serves gets matching firmware by passing that through.

Only gfx1250 has stubs. The fixture filenames carry IP versions -- `gc_12_1_0`,
`sdma_7_1_0` -- so upstream's table is that generation's alone, and
`rj-ip-discovery` knows one generation too. The other thirteen profiles are
refused by name:

```
$ vfio_guest_firmware.py --config gfx950_mi355x.json --output /out
vfio guest firmware generation failed: gfx950_mi355x.json models gfx950
(gfx_target_version 90500); stub generation covers gfx1250 only
```

That is the point of deriving it: before, a non-gfx1250 config got gfx1250 stubs
and failed as a guest that never brought up a GPU.

Pass `--no-ip-discovery` to emit the header fixtures alone and leave
`ip_discovery.bin` to a separate `rj-ip-discovery` call. The manifest then names
only what was written.

### The two MES aliases

`gc_12_1_0_mes.bin` and `gc_12_1_0_mes1.bin` are byte-identical to
`gc_12_1_0_uni_mes.bin`, and that is correct rather than a shortcut. Real
`mes.bin` (the pipe 0 scheduler) and `mes1.bin` (the kernel interface queue)
are distinct blobs, but these are headers over a sentinel payload, not
microcode: `amdgpu` parses the header and the version word in
`amdgpu_mes_init_microcode()` and never executes what follows. One fixture is
therefore right under all three names, which is why the generator emits them
here instead of leaving callers to copy the file. `amdgpu` only opens the two
aliases when `amdgpu_uni_mes=0`, which is not the default.

### Vendoring upstream's builders

`/usr/local/bin/vfio_guest_firmware.py` is this repo's
([`vfio-guest-firmware.py`](vfio-guest-firmware.py)), and the fixture builders
in it are upstream's, vendored verbatim from `730bc62` -- the last commit that
carried `emulation/rocjitsu/tools/vfio_guest_firmware.py` before it was
deleted. They were fetched at build time until that became untenable: the only
way to fetch a deleted file is from a commit on a branch, and the branch it
lived on has already been deleted once and any replacement can be pruned at any
time.

Nothing upstream will take this back. `develop` documents the firmware step and
hands it to the operator -- there is no executable firmware handling anywhere
in it, and no CI that enables `ROCJITSU_ENABLE_VFIO` -- so covering the gap is
this repo's job indefinitely, and it should be a file in this repo rather than
a pin at a commit that can stop resolving.

## Usage

The default command serves the pinned config on
`${ROCJITSU_SOCKET_DIR}/rocjitsu.sock`:

```bash
docker run --rm -v /run/rocjitsu:/run/rocjitsu \
  docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:latest
```

Point QEMU's vfio-user client at that socket.

### Environment

| Variable | Default |
| --- | --- |
| `ROCJITSU_CONFIG_DIR` | `/usr/local/share/rocjitsu/configs` |
| `ROCJITSU_SOCKET_DIR` | `/run/rocjitsu` |
| `ROCJITSU_CONFIG_PATH` | `${ROCJITSU_CONFIG_DIR}/gfx1250_mi455x.json` |

Only `gfx_target_version` 120500 has an IP discovery profile upstream, so
`gfx1250_mi455x.json` is the only config the vfio-user front end can actually
serve today. It is a spec var so a variant built against a different upstream
ref can point at a renamed or newly added profile without touching the
Dockerfile.

## Large BAR

The image ships the served device with a 256 GiB VRAM BAR. Upstream ships it
at 268435456 -- 256 MiB, the small-BAR ceiling -- so a guest saw a 256 MiB
window onto a 432 GiB device and paged everything else through the GART.

It is a config field and nothing else: `vm.gpu.pci.vram_aperture_bytes` in
`gfx1250_mi455x.json`. There is no CLI flag and no environment variable
rocjitsu reads instead, which is why the only place this can be set is in the
image, before it is sealed. `rocjitsu_vram_aperture` in
[`images.yml`](../images.yml) is the knob; it defaults to `max`, takes `keep`
to reproduce upstream's small BAR, and takes an explicit power-of-two byte
count.

`max` is the largest power of two that is not larger than the profile's own
`vm.gpu.device.local_mem_size` -- 256 GiB against this profile's 432 GiB --
because those are the two bounds rocjitsu itself enforces:

| `vram_aperture_bytes` | rocjitsu says |
| --- | --- |
| 128 GiB | clean, serves |
| 256 GiB | clean, serves |
| 300 GiB | warns: the aperture is not a power of two |
| 512 GiB | warns: the aperture is larger than the memory itself |

Both of those are warnings, not errors -- the device still serves -- so the
build-time probe fails on any line mentioning `aperture`, and the resolved byte
count is written into `rocjitsu-build.json` and
`/usr/local/share/rocjitsu-vram-aperture.txt`. The `…rocjitsu.vram-aperture`
label carries what was asked for, which is `max` on a default build.

No QEMU-side change is needed to place it. q35 sizes its own 64-bit PCI hole
around the BARs the device advertises, so `info pci` against a guest attached
to this image reports, with no `pci-hole64-size` set and nothing else changed:

```text
Class 4608: PCI device 1002:75c1
  BAR0: 64 bit prefetchable memory at 0x4000000000 [0x7fffffffff]
  BAR2: 64 bit prefetchable memory at 0x8000000000 [0x80001fffff]
```

which is the 256 GiB VRAM window followed by the 2 MiB doorbell -- both
mapped, where the small-BAR build left BAR2 unmapped. Setting
`pci-hole64-size` explicitly changes neither line; what it does have is a
ceiling, because the default `qemu64` CPU model has 40 physical address bits
and a 1T hole is refused outright with `phys-bits too low (40)`.

vfio-user P2P DMA is a separate matter and still needs the fork QEMU image
rather than the stock one.

### Why only one profile gets this

Both image variants carry it -- `-sbates-fork` inherits the var -- and the
window follows whatever `rocjitsu_config` names, computed from that profile's
own `local_mem_size`, so repointing the var needs no edit. The other 14
profiles in `configs/` are left alone on purpose:

- `gfx1250_mi455x.json` is the only one upstream gives a `vm.gpu.pci` block at
  all. The rest model no PCI device, so there is no BAR to size.
- A block can be added to them and rocjitsu will take it, but every non-120500
  target then warns `has no IP discovery profile ... a guest driver would find
  nothing to attach to`. The window would be one no guest can reach.
- `gfx1250_mi455x_kmd_4gpu.json` is the near miss -- same `gfx_target_version`
  120500 -- but it exits 1 when served, unmodified and with no aperture set,
  because it describes four GPUs and this transport presents one function.

The helper creates the `pci` block when a config lacks one rather than
refusing, so repointing `rocjitsu_config` at a profile upstream never gave one
does not fail the build. It still refuses `max` on a profile that states no
`local_mem_size` -- `gfx1251_synthetic.json` and the three `guest_*` configs
-- since there is nothing to size against; use `keep` for those.

Guests are unaffected either way. The `ubuntu-qcow2-gen` rocjitsu flavours
carry no copy of this: the BAR comes from whichever server they are booted
against.

This is unrelated to the amdgpu `vramlimit` parameter, which several documents
here mention alongside it. That is the budget ROCr provisions queue scratch from;
this is the BAR window.

## Logging

The server is built with `RJ_LOG_GROUPS=OFF`. Group logging is compiled in,
not switched on: `util/log.h` reads the cmake value into a `constexpr` bitmask
and there is no environment variable to quieten it. Every covered event prints,
through a shared mutex, for the life of the container -- so a group left on is
a group that narrates every event it covers, at whatever rate a guest generates
them.

`CP` -- the command processor's doorbell, dispatch and completion path -- was
on while the patch series was being proven out, and it is the group to turn
back on when a dispatch is accepted but never completes. It is off by default
because that volume is not worth paying for a server that is working. `VM` logs
instruction execution and is not a thing to leave on in a server a guest is
booting against at all.

Warnings and errors are not part of this and print regardless, which is why the
build-time `vfu: serving` probe still works with every group off.

Change it with the `rocjitsu_log_groups` var in [`images.yml`](../images.yml),
or `ROCM_ROCJITSU_LOG_GROUPS` in the environment: `OFF`, `ALL`, a
comma-separated subset, or a raw bitmask. The value is recorded in the
`…rocjitsu.log-groups` label and in `rocjitsu-build.json`, so what an image
prints can be read off the image.

## Verifying an image

A green `docker build` proves the server compiles and serves, not that a guest
can use it. The build-time checks are cheap and catch most regressions:

```bash
# expect the pinned commit and an empty local_patches
docker run --rm --entrypoint sh "$IMAGE" -c \
    'cat /usr/local/share/rocjitsu-build.json'
# expect an 848-byte discovery table
docker run --rm --entrypoint sh "$IMAGE" -c \
    'rj-ip-discovery gfx1250 /tmp/x.bin && wc -c /tmp/x.bin'
```

The real acceptance test is a guest, and it has to be re-run on every pin bump
now that the pin tracks a force-pushed branch:

1. Boot a guest against the image and probe `amdgpu` with `emu_mode=1
   fw_load_type=0 discovery=2 ip_block_mask=0x3f vm_update_mode=3
   gpu_recovery=0 vramlimit=256`. The GART root and translator behaviour is
   what gets you past this. Without it: `Timeout waiting for VM flush ACK!`
   followed by >100k identical MES warnings against `0x6c00001260`, or `ring
   sdma0.0 timeout, signaled seq=2, emitted seq=3` in `kfd_ioctl_acquire_vm`.
2. Build and run `rocjitsu-scratch-repro.hip` in the guest. The dynamic-scratch
   handshake is what gets you past this; without it the dispatch hangs forever
   with no error.
3. Run `rocm-xio`'s `test-vm-nvme` with `ROCJITSU_IMAGE` pointed at the
   candidate. Judge the image on steps 1 and 2 -- the `nvme` label is not
   currently green on any image.

### Limits of the emulation

- The emulated device backs roughly 43 MB of scratch in total, and ROCr
  provisions for full occupancy regardless of grid size, so a kernel needing
  more than about 1300 B/thread of private segment fails or hangs anyway.
- A second `modprobe amdgpu` against a live rocjitsu hangs in
  `sdma_v7_1_ring_test_ring`. Not root-caused. CI boots fresh and probes once,
  so it only bites interactive debugging.
- Upstream ROCr has a one-queue scratch deadlock in `AcquireQueueMainScratch`
  -- not a rocjitsu defect, and not fixed here.

## Pin

`rocjitsu_commit` in [`images.yml`](../images.yml), on `develop`. It followed
`users/agutierr/gfx1250-vfio-compute-6` while the vfio-user compute path
existed only there; that stack was squashed onto `develop` as `bdc4aea25` and
`d5927b503` and the branch deleted, so the pin it used to carry is not an
ancestor of anything that still exists.

The pin tracks the branch head: `scripts/version-scrub.sh` bumps `images.yml`
and the Dockerfile `ARG` together. Nothing upstream exercises this path, so a
scrubbed bump is not self-evidently safe -- re-prove it against a guest before
a consumer takes it, per [Verifying an image](#verifying-an-image).

## Variants

| Variant | Repository suffix | What differs |
| --- | --- | --- |
| *(default)* | *(none)* | `develop`, with libvfio-user as upstream's own cmake pins it: `nutanix/libvfio-user` at `v0.8` |
| `sbates-fork` | `-sbates-fork` | `users/stebates/rocjitsu-vfio-doorbell`, built against the `sbates130272` libvfio-user fork and **calling** the doorbell and `vfu_mmio_write` paths |

Unlike the other `sbates-fork` variants, this one cannot simply layer on a
different base: rocjitsu's libvfio-user is pinned inside upstream ROCm's
`emulation/rocjitsu/cmake/rj_libvfio_user.cmake`, not by anything this repo
owns. So the Dockerfile clones the fork itself and redirects upstream's
`FetchContent_Declare` with CMake's documented per-dependency escape hatch,
`-DFETCHCONTENT_SOURCE_DIR_LIBVFIO-USER=…`. The rocm-systems tree is still built
unmodified, so [Local patches](#local-patches) stays accurate and
`local_patches` stays `[]`.

`libvfio_user_override_repo` and `libvfio_user_override_commit` in
[images.yml](../images.yml) are empty by default, and the override only engages
when both are set. They are deliberately *not* the shared
`libvfio_user_repo`/`libvfio_user_commit`, which always hold a real upstream SHA
and would therefore repoint every default build.

This is a short forward step on the tree rocjitsu already pins rather than a
cross-tree swap, which is what makes it buildable: `v0.8` is commit `37491ed`,
the fork's base is five commits later, and the fork adds two more. The only
public-header change is additive, so every `vfu_*` symbol rocjitsu's
`vfio_device_host.cpp` uses is declared identically in both — and `lib/`'s
source list is unchanged, which matters because `rj_libvfio_user.cmake`
hand-lists those files.

Unlike the ernic and SPDK variants, this one does not merely make the API
reachable — it pins a rocjitsu that uses it. On
`users/stebates/rocjitsu-vfio-doorbell`, `vfio_device_host.cpp` calls
`vfu_setup_host_doorbell_cb()` once and `vfu_mmio_write()` three times, making
this the one image where the doorbell path is actually exercised. That branch
also points its own `rj_libvfio_user.cmake` at the fork, at the same SHA, so
the `FETCHCONTENT_SOURCE_DIR` override is belt-and-braces here rather than the
mechanism. It is kept because it pins the library from this repo even if the
branch's cmake drifts, and because it is what the build-time assert checks — a
misspelled or ignored variable would otherwise fall back to `v0.8` and produce
a green build of the wrong library.

The branch is **diverged from `develop`, not ahead**: three commits on, fifteen
behind the commit the default target carries. The variant is therefore older
than the default in everything except the doorbell work, and the two are not
comparable builds. Repin it to a rebase, or to `develop`, once the work lands.

## Tags

The tag variant is the abbreviated commit, for example `rocjitsu.98f6a72`; the
`sbates-fork` variant appends the libvfio-user commit and carries its own
rocjitsu pin, `rocjitsu.faacfb0-vfu.3719c3a`, because upstream's libvfio-user
pin is not a var here and the two would otherwise collide. The
full tag also carries `g<sha7>` of this repository, so a change to the wrapper
or the Dockerfile moves the tag even when the upstream pin has not. See the
repository [README](../README.md) for the full tag scheme.
