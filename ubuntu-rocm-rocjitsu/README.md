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
- **`vfio_guest_firmware.py`** -- generates the complete guest firmware set: the
  GFX/SDMA/MES firmware-format fixtures the driver parses during early init,
  `ip_discovery.bin`, and a manifest naming every file. The upstream generator
  covers the fixtures alone; this image fetches it from the last commit that had
  it, pinned separately from the server's own commit, and wraps it. See
  [Firmware](#firmware) below.
- the config profiles under `/usr/local/share/rocjitsu/configs`
- `/usr/local/share/rocjitsu-build.json`, recording the repo, branch, commit,
  the libvfio-user and json-c tags built against, and the guest tools shipped

### Build-time verification

Four checks run in the image build, so a broken stack fails where the output
is legible rather than as a hung guest:

1. `rocjitsu` is started against the pinned config and must log `vfu: serving`
   with a live socket
2. `rj-ip-discovery gfx1250` must produce a non-empty artefact -- a guest given
   an empty `ip_discovery.bin` hangs in `hw_init` instead of failing cleanly
3. `run-vfio-guest.py --help` must run, which catches a Python the base image
   cannot import it under
4. `vfio_guest_firmware.py` must emit every file its own manifest names, the
   two MES aliases must carry the `uni_mes` bytes, and a config it has no
   firmware for must be refused rather than served gfx1250 stubs

## Firmware

Upstream removed the stub generator when `emulation/rocjitsu/docs/qemu-vfio.md`
moved to "use firmware files from the same public driver/firmware release as
the guest's `amdgpu.ko`". No such release exists for gfx1250:
`amdgpu-dkms-firmware 31.50`, the newest driver tree with an Ubuntu 26.04 suite,
ships 683 files and not one `gc_12_1_0` or `sdma_7_1_0` among them, and
`linux-firmware` has none either. Stubs are therefore still the only way to boot
the emulated device, and this image keeps shipping the generator --
`ROCJITSU_FIRMWARE_GEN_COMMIT`, recorded in the
`…rocjitsu.firmware-gen-commit` label and in `rocjitsu-build.json`. Retire the
pin when real gfx1250 firmware is published.

One call produces the whole set:

```bash
docker run --rm -v "$PWD/fw:/out" "$IMAGE" \
    python3 /usr/local/bin/vfio_guest_firmware.py --output /out
```

That writes `gc_12_1_0_imu.bin`, `gc_12_1_0_mec.bin`, `gc_12_1_0_mes.bin`,
`gc_12_1_0_mes1.bin`, `gc_12_1_0_rlc_1.bin`, `gc_12_1_0_uni_mes.bin`,
`sdma_7_1_0.bin`, `ip_discovery.bin` and a `manifest.json` naming them:

```json
{
  "generation": "gfx1250",
  "gfx_target_version": 120500,
  "config": "gfx1250_mi455x.json",
  "files": ["gc_12_1_0_imu.bin", "..."]
}
```

Copy the files into the guest's `/lib/firmware/amdgpu/` and assert against the
manifest rather than a filename of your own -- then a firmware file added here
needs no change on the consuming side.

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
here instead of leaving callers to copy the file.

### Wrapping upstream

The upstream generator is installed at
`/usr/local/lib/rocjitsu/vfio_guest_firmware_upstream.py` and
`/usr/local/bin/vfio_guest_firmware.py` is this repo's wrapper around it
([`vfio-guest-firmware.py`](vfio-guest-firmware.py)). The fixture bytes are
still upstream's -- the wrapper calls its builders rather than copying them --
so an upstream change to a header flows through untouched. What the wrapper adds
is everything a consumer would otherwise have to know about this device model:
the MES aliases, the generation, and the manifest.

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

## Logging

The server is built with `RJ_LOG_GROUPS=CP`, so the command processor --
doorbell, dispatch, completion -- narrates itself on stdout as `[rj log CP]`.
That is the path a guest drives through the vfio-user front end, and the one
worth having when a dispatch is accepted but never completes.

It is compiled in, not switched on: `util/log.h` reads the cmake value into a
`constexpr` bitmask and there is no environment variable to quieten it. Every
covered event prints, through a shared mutex, for the life of the container.
The other groups (`VM`, `DBT_HOOKS`, `PLUGINS`, `DRIVER`) are off for that
reason -- `VM` logs instruction execution, which is not a thing to leave on in
a server a guest is booting against.

Change it with the `rocjitsu_log_groups` var in [`images.yml`](../images.yml),
or `ROCM_ROCJITSU_LOG_GROUPS` in the environment: `OFF`, `ALL`, a
comma-separated subset, or a raw bitmask. The value is recorded in the
`…rocjitsu.log-groups` label and in `rocjitsu-build.json`, so what an image
prints can be read off the image.

## Pin

`rocjitsu_commit` in [`images.yml`](../images.yml), tracking
`rocjitsu_branch`. That branch is currently
`users/agutierr/gfx1250-vfio-compute-6`, the tip of a stacked review series,
not `develop`: the vfio-user compute path only exists there. Expect
force-pushes while the stack is in review -- `scripts/version-scrub.sh` bumps
the pin on every reviewer round-trip and warns rather than bumps once the
branches are deleted. Both should go back to `develop` after the merge; that
is the whole reason the pin is temporary.

## Tags

The tag variant is the abbreviated commit, for example `rocjitsu.be38974`. See
the repository [README](../README.md) for the full tag scheme.
