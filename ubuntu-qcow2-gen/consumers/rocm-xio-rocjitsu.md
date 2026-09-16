# Guest image request: ROCm/rocm-xio, rocjitsu emulated GPU

Status: **image built and published.** Three of the four asks landed; firmware
did not, by agreement. Read [Firmware](#firmware-is-not-baked-in) and
[Which driver actually loads](#which-driver-actually-loads) before removing
anything from rocm-xio's runtime playbook — the second one changes what the
atomics patch buys you.

## What was asked for

rocm-xio's `test-vm-nvme` workflow installs ROCm userspace and builds
`amdgpu-dkms` over SSH at job time, which costs the better part of an hour on
every run. The ask was to move that into the guest disk, following the `ionic`
flavour's shape.

| # | Asked for | Landed |
| --- | --- | --- |
| 1 | ROCm userspace from the `therock` stream: `libstdc++-14-dev`, `amdrocm-runtime-dev`, `amdrocm-blas-dev` | yes — but see [BLAS](#amdrocm-blas-dev-is-headers-only) |
| 2 | `amdgpu-dkms` built against the guest kernel, KFD atomics patch applied first | built and patched, but against 6.8, **not** the kernel the guest boots — see below |
| 3 | gfx1250 firmware present under `/lib/firmware`, asserted in the checks | **no**, by agreement |
| 4 | `blacklist amdgpu` in `/etc/modprobe.d/` | yes |

The "nice to have" list — `build-essential`, `cmake`, `git`, `pciutils`,
`nvme-cli` — is in, along with the rest of rocm-xio's build dependencies.

Everything on the "do not want" list stays out: no `ip_discovery.bin`, no
`amdgpu-probe` helper, no passwordless sudo.

## Which driver actually loads

The guest boots **7.0.0-31-generic** (noble's HWE kernel) and the driver that
loads is the **in-tree** amdgpu from it. That is the point of the flavour: 7.0
is the first kernel whose in-tree amdgpu has GC 12.1.0, and it names all seven
gfx1250 blobs —

```
gc_12_1_0_rlc.bin  gc_12_1_0_mec.bin  gc_12_1_0_imu.bin  sdma_7_1_0.bin
gc_12_1_0_uni_mes.bin  gc_12_1_0_mes1.bin  gc_12_1_0_mes.bin
```

— where `amdgpu-dkms` names none of them. `checks/rocjitsu.sh` asserts both the
kernel floor and those firmware references, so a guest that came up on the
cloud image's 6.8, or on a driver without gfx1250, cannot be published.

`amdgpu-dkms` **is** installed, patched and built, but for 6.8 only. It cannot
be built for 7.0 at all: it is a `~24.04` package whose `kcl` compatibility
layer fails on `migrate_enable`, `zone_device_page_init` and `shmem_file_setup`,
and on 7.0 it also hits `drm_client_dev_resume` and `pci_resize_resource`
signature changes. So what the image carries is a patched source tree plus an
inert 6.8 module, not the driver that runs.

**Consequence for the atomics patch: it is not in the loaded driver.** If KFD's
PCIe-atomics gate does fire against the emulated device on the in-tree 7.0
driver, the patch in `/usr/src/amdgpu-*` will not help, because that tree is not
what `modprobe amdgpu` loads. The in-tree module does still expose `emu_mode` as
a parameter, and `strings` on it still shows the `PCI rejects atomics` message,
so the gate exists in the code path — whether it is reached for this device is
not something this image's GPU-less probe boot can determine. First real
evidence is a rocm-xio run.

### Ordering, and why it differs from qemu-minimal

qemu-minimal's `ansible/playbooks/vm-rocjitsu.yml` (as of PR #136) installs
`linux-generic-hwe-24.04` first and `amdgpu-dkms` second, which is the order the
`rocm_setup` role imposes. That does not work: `amdgpu-dkms`'s postinst builds
for **every kernel with headers on disk**, not for the running one, so with 7.0
headers already present it dies with exit status 10 and the package is left
unconfigured. This flavour reverses the two — DKMS while only 6.8 headers exist,
then the HWE kernel — which is the only reason it has a built module at all.

Installing the kernel afterwards then trips the same failure from
`/etc/kernel/postinst.d/dkms`, which would leave `linux-image-7.0.0-31-generic`
unconfigured. `/etc/dkms/no-autoinstall-errors` (the autoinstaller's own
documented flag) is written first so the attempt still happens and the error is
not propagated. It is left in the published image, so a consumer installing a
later kernel gets the module if it builds and a working kernel if it does not.

Worth fixing on the qemu-minimal side too, or its next rebuild produces a guest
with no `amdgpu.ko` from DKMS and an unconfigured kernel package.

## Firmware is not baked in

Not a build failure — this was dropped on request, and the checks do not assert
it.

It is, however, **obtainable**, which is a change from the earlier read. No
public driver release ships gfx1250 blobs (the newest `amdgpu-dkms-firmware` on
`repo.radeon.com` carries 674 amdgpu files and zero `gc_12_1_0` or
`sdma_7_1_0`), but qemu-minimal does not get them from a package either: it runs
`vfio_guest_firmware.py` and `rj-ip-discovery` out of the rocjitsu container.
That generator was removed from the current stack, which is exactly why PR #136
pins `sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:rocjitsu.730bc62`
rather than `:latest`. It also copies `gc_12_1_0_uni_mes.bin` over
`gc_12_1_0_mes.bin` and `gc_12_1_0_mes1.bin`, which the generator does not emit.

So baking firmware here is possible — a builder stage on that pinned tag — at
the cost of depending on a pinned image whose generator no longer exists in
source. Say the word and it goes in.

For now **rocm-xio keeps firmware in its runtime playbook**, together with
`ip_discovery.bin`, which was already on the "do not want" list because it must
match the consumer's rocjitsu pin, not this image's.

[`checks/rocjitsu.sh`](../checks/rocjitsu.sh) runs the inventory and prints what
is missing without failing. One note if you keep an assert on the rocm-xio side:
the pattern `gc_12_1_0|sdma_7_1_0|mes` is too loose — `mes` matches gc_11 and
gc_12_0 blobs that are present, so it can pass on a guest carrying none of the
gfx1250 firmware it was written to check for. The check here is scoped to
`gc_12_1_0|sdma_7_1_0` only.

## `amdrocm-blas-dev` is headers-only

In the `therock` stream `amdrocm-blas-dev` depends on `libc6` and nothing else —
it installs `hipblas`, `hipblaslt` and `rocblas` headers and **no shared
library**. The runtime lives in `amdrocm-blas`, which pulls a per-architecture
kernel package for every gfx target including `gfx1250`.

The image installs exactly the three packages that were asked for, so it has the
headers and not `librocblas.so`. That links, and fails at load time.
[`checks/rocjitsu.sh`](../checks/rocjitsu.sh) asserts the header rather than
pretending otherwise.

If rocm-xio needs BLAS at run time, `amdrocm-blas` is a one-line addition to
[`provision/rocjitsu.sh`](../provision/rocjitsu.sh) — but it is a change to the
stated minimal set and a material size increase, so it is not being made
unilaterally.

## Pins, and why

**`release: noble`, not the catalogue default `resolute`.**
`repo.radeon.com/amdgpu/*/ubuntu/dists/` publishes `jammy` and `noble` only;
`resolute` is a 404. There is no 26.04 guest that can install `amdgpu-dkms` from
AMD at all. TheRock userspace does publish both `ubuntu2404` and `ubuntu2604`,
so it is the kernel driver alone that forces the pin.

**`amdgpu_driver_version: latest`, not `7.0.3`.**
The numbered directories track the ROCm release, not the driver. 7.0.3 ships
amdgpu-dkms 6.14.14; `latest` is 6.16.13. Neither builds against 7.0, which is
why the build happens on 6.8 — but `latest` is the `rocm_setup` role default, so
this flavour and the qemu-minimal playbook install the same driver.

## What the guest records about itself

`/etc/rocjitsu-guest.json`, written during provisioning, from the published
build:

```json
{
  "amdgpu_driver_repo_version": "latest",
  "amdgpu_dkms_version": "1:6.16.13.30300400-2341068.24.04",
  "amdgpu_dkms_module": "6.16.13-2341068.24.04",
  "amdgpu_dkms_built_for_kernel": "6.8.0-139-generic",
  "booted_kernel": "7.0.0-31-generic",
  "amdrocm_runtime_dev_version": "10.0.0-4",
  "rocm_stream": "therock",
  "kfd_atomics_patched": true,
  "kfd_atomics_patch_applies_to": "amdgpu-dkms source only, not the in-tree driver",
  "runtime_driver": "in-tree amdgpu from the booted HWE kernel",
  "amdgpu_autoload_blacklisted": true,
  "gfx1250_firmware": false,
  "ip_discovery_bin": false
}
```

`amdgpu_driver_repo_version` names a repository, not a build, which is why the
resolved package version is recorded next to it. The last two fields are false
on purpose and are the contract for what rocm-xio must still do at runtime.

## What rocm-xio still has to do at job time

1. Install gfx1250 firmware and `ip_discovery.bin` into `/lib/firmware/amdgpu/`.
2. `modprobe amdgpu` with the emulation parameters once the vfio-user server is
   serving. The image blacklists autoload but ships no helper; keep
   `amdgpu-probe` on the rocm-xio side, where the parameters belong.

Everything else in the current playbook — apt sources, keyrings, ROCm userspace,
the kernel, the DKMS install, the patch, the rebuild — is already in the disk.

## Publishing contract

Unchanged from `basic`: a `FROM scratch` payload whose `/output` carries the
qcow2, `id_rsa`, `id_rsa.pub` and `vm-info.json`. `vm-info.json` keeps
`vm_name`, `username`, `release` and `kernel_release` (now `7.0.0-31-generic`),
and is `schema_version: 4` — the only addition is `provisioning.provision`,
naming the in-guest script. Flavour-specific versions stay in the guest's own
record rather than leaking into this file.

Consume an explicit dated tag, never `:latest`.

## Open

- The image cannot be end-to-end tested here. The build's probe boot has no
  vfio-user device, so it asserts that everything is installed and patched, not
  that the emulated GPU comes up. First real proof is a rocm-xio run.
- Whether the KFD atomics gate fires for the emulated device under the in-tree
  7.0 driver is unresolved. If it does, the fix has to move into the in-tree
  driver — a `kfd_device.c` patch plus a kernel build — because the DKMS tree
  the patch currently lands in is not what loads.
- `test-vm-nvme.yml` is not on rocm-xio's default branch, so the runtime path it
  replaces has never run in CI either. Landing that workflow and this image
  together is worth doing in one go.
</content>
</invoke>
