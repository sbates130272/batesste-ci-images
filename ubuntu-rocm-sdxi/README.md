# ubuntu-rocm-sdxi

An emulated AMD SDXI data-mover served over vfio-user, so a guest needs no SDXI
silicon.

SDXI is the SNIA-standardised data-exchange interface AMD is integrating into
CPU SoCs. This image runs `rocm-sdxi`, a userspace vfio-user server that
presents an SDXI copy engine to QEMU over a Unix socket — no kernel device
model, and no hardware. Software targeting SDXI can therefore be written and
measured in a VM before silicon or FPGA targets exist.

It completes the set of device servers in this repo: `ubuntu-rocm-ernic` serves
a NIC, `ubuntu-rocm-rocjitsu` serves a GPU, `ubuntu-spdk-libvfio-user` serves an
NVMe controller, and this serves a data-mover.

## What it serves

- SQ/CQ descriptor rings, NVMe-style
- `MEMCPY`, `MEMSET` and `FENCE` descriptors
- `COMPRESS`/`DECOMPRESS` with zlib, LZ4 and Zstd
- Elementwise arithmetic `COMPUTE` descriptors
- Up to 16 queues, MSI-X per queue
- BAR0 (64 KiB MMIO registers) and BAR2 (4 MiB doorbell aperture)

## Running it

```sh
docker run --rm -v /run/rocm-sdxi:/run/rocm-sdxi \
    sbates130272/batesste-ci-images-ubuntu-rocm-sdxi:latest
```

The default command serves `${SDXI_SOCKET_DIR}/rocm-sdxi.sock` with `-v`. The
verbosity is not cosmetic: `rocm-sdxi` logs at WARN by default and its
readiness line is INFO, so a server started without `-v` is completely silent
when healthy — which reads as a hang. Attach a guest with:

```sh
qemu-system-x86_64 ... -device vfio-user-pci,socket=/run/rocm-sdxi/rocm-sdxi.sock
```

All log output goes to **stderr**. The only thing written to stdout is
`rocm-sdxi --version`.

## What it carries for the guest

`/usr/local/share/rocm-sdxi/` stages the guest-side source at the same pin this
server was built from:

| Path | What it is |
| --- | --- |
| `drivers/sdxi_char/` | The char driver. Binds PCI `1022:149f`, creates `/dev/sdxi<devfn>` as a misc device, and carries `sdxi_user.h` — the uapi this server and the guest agree on. |
| `drivers/sdxi_perf/` | A debugfs counter driver. **Does not build out of tree**; see below. |
| `tools/sdxi-cli/` | The CLI, both a C program and a Python package. |

These are staged, not built: a kernel module has to be compiled against the
kernel the guest boots, which is not this container's. `ubuntu-qcow2-gen`'s
`rocjitsu` flavour fetches its own copy at the same pin and builds it there.
`images.yml` requires the two pins to be equal, and `version-scrub.sh` warns
when they diverge — `sdxi_user.h` carries the ioctl numbers and struct layouts
both sides depend on, so a mismatch surfaces as a bare `EINVAL` from `sdxi-cli`
rather than as anything naming the cause.

### sdxi_perf does not build

Three separate upstream problems, any one of which fails an out-of-tree build:

1. `sdxi_perf.c:194` declares `MODULE_LICENSE("MIT")`. Plain `MIT` is not on the
   kernel's GPL-compatible list, while every debugfs symbol the module uses is
   `EXPORT_SYMBOL_GPL`, so modpost will not resolve them. `Dual MIT/GPL` is the
   one-word fix and leaves the SPDX tag alone.
2. `sdxi_perf.c:66` declares `u64 val` after a statement.
   `-Wdeclaration-after-statement` plus `CONFIG_WERROR`, default `y` since 6.1,
   makes that an error for out-of-tree modules.
3. It reads BAR0 via `pcim_iomap_table()`, deprecated since ~6.11 and slated for
   deletion. The replacement returns an `ERR_PTR`, so the port is not a rename.

Nothing the guest needs is lost. Both modules claim the same PCI ID, so only one
could ever bind the device, and `sdxi_char` already exposes the same counters
through `SDXI_IOC_STATS`.

## Provenance

`/usr/local/share/rocm-sdxi-build.json` records the pin, the libvfio-user that
was really linked, and which source supplied it:

```json
{
  "sdxi_commit": "…",
  "libvfio_user_source": "sdxi-cmake",
  "libvfio_user_upstream_tag": "v0.8",
  "libvfio_user_tag": "v0.8",
  "guest_modules": ["sdxi_char"]
}
```

`libvfio_user_upstream_tag` is what `cmake/SdxiVfioUser.cmake` declares;
`libvfio_user_tag` is what was actually built. They differ only when
`LIBVFIO_USER_REPO`/`LIBVFIO_USER_COMMIT` override the fetch, and the split
exists so an override build's own provenance cannot lie.

## The pin

`sdxi_commit` names a commit on `users/stebates/emulation-sdxi` in
`ROCm/rocm-systems` — a personal branch, because `emulation/sdxi` does not
exist on `develop` at all.

`version-scrub.sh` **reports** when that branch has moved and never rewrites
the pin. That is a sharper rule than the one `rocjitsu` gets: a personal branch
is rebased and force-pushed as the series is reworked, so its head is routinely
not a descendant of what is pinned here. An automatic bump would not be a bump,
it would be a jump sideways onto a tree nobody has reviewed.
