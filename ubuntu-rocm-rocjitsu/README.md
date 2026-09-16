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
- **`vfio_guest_firmware.py`** -- generates the GFX/SDMA/MES firmware-format
  fixtures the driver parses during early init. Upstream deleted it; this image
  fetches it from the last commit that had it, pinned separately from the
  server's own commit. See [Firmware](#firmware) below.
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
4. `vfio_guest_firmware.py` must emit all five of its fixtures by name

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

```bash
docker run --rm -v "$PWD/fw:/out" "$IMAGE" \
    python3 /usr/local/bin/vfio_guest_firmware.py --output /out
docker run --rm -v "$PWD/fw:/out" "$IMAGE" \
    rj-ip-discovery gfx1250 /out/ip_discovery.bin
```

That produces `gc_12_1_0_imu.bin`, `gc_12_1_0_mec.bin`, `gc_12_1_0_rlc_1.bin`,
`gc_12_1_0_uni_mes.bin` and `sdma_7_1_0.bin`, plus `ip_discovery.bin`. Two more
files are the caller's to make, because only the caller knows which MES path its
`amdgpu.ko` takes: copy `gc_12_1_0_uni_mes.bin` to `gc_12_1_0_mes.bin` and
`gc_12_1_0_mes1.bin`. The 7.1.3 driver also opens `psp_15_0_8_toc_1.bin`, which
nothing public provides and this generator does not emit; the similarly named
`psp_15_0_0_toc.bin` and `psp_15_0_9_toc.bin` are different parts and must not
be substituted.

`ip_discovery.bin` must come from the same rocjitsu commit that serves the
device, which is why it is generated here rather than shipped in a guest disk.

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

The tag variant is the abbreviated commit, for example `rocjitsu.909c17f`. See
the repository [README](../README.md) for the full tag scheme.
