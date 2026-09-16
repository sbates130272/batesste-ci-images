# Guest image request: ROCm/rocm-xio, rocjitsu emulated GPU

Status: **image built and published, now on resolute.** The earlier noble build
carried a DKMS module that could never load; this one carries the driver that
does. Read [Which driver actually loads](#which-driver-actually-loads) and
[Firmware](#firmware-is-not-baked-in) before removing anything from rocm-xio's
runtime playbook.

## What was asked for

rocm-xio's `test-vm-nvme` workflow installs ROCm userspace and builds
`amdgpu-dkms` over SSH at job time, which costs the better part of an hour on
every run. The ask was to move that into the guest disk, following the `ionic`
flavour's shape.

| # | Asked for | Landed |
| --- | --- | --- |
| 1 | ROCm userspace from the `therock` stream: `libstdc++-14-dev`, `amdrocm-runtime-dev`, `amdrocm-blas-dev` | yes — but see [BLAS](#amdrocm-blas-dev-is-headers-only) |
| 2 | `amdgpu-dkms` built against the guest kernel, KFD atomics patch applied first | yes, since the move to resolute |
| 3 | gfx1250 firmware present under `/lib/firmware`, asserted in the checks | **no**, by agreement — no public release ships it |
| 4 | `blacklist amdgpu` in `/etc/modprobe.d/` | yes, plus `modprobe.blacklist=amdgpu` on the kernel cmdline |

The "nice to have" list — `build-essential`, `cmake`, `git`, `pciutils`,
`nvme-cli` — is in, along with the rest of rocm-xio's build dependencies.

Everything on the "do not want" list stays out: no `ip_discovery.bin`, no
`amdgpu-probe` helper, no passwordless sudo.

## Which driver actually loads

`amdgpu-dkms 1:7.1.3.31500000`, built for the kernel the guest boots
(`7.0.0-31-generic`), carrying the KFD atomics patch in the module itself and
not only in its source tree. `modprobe amdgpu` resolves to
`/lib/modules/<kver>/updates/dkms/amdgpu.ko`, ahead of the in-tree module, and
`checks/rocjitsu.sh` asserts exactly that: `dkms status amdgpu -k "$(uname -r)"`
reporting `installed`, and `modinfo -n amdgpu` resolving under `updates/dkms`.

This is the driver version the one known-good hand-built guest reports
(`[drm] amdgpu version: 7.1.3.31500000`), and it enumerates eight IP blocks with
psp/smu/mes present. It contains the UMSCH HW IP enumeration
(`4e07da515d1c`) that upstream names as the fix for

```
Failed to add vcn/jpeg ip block(UVD_HWIP:0x0)
amdgpu: probe with driver amdgpu failed with error -22
```

which is what the in-tree 7.0 driver does with this compute-only device.

### Why the release changed, and the ordering that goes with it

The noble build could only install a `~24.04` `amdgpu-dkms` whose `kcl`
compatibility layer does not compile against 7.0 at all (`migrate_enable`,
`zone_device_page_init`, `shmem_file_setup`, then `drm_client_dev_resume` and
`pci_resize_resource`). Because its postinst builds for **every kernel with
headers on disk** rather than for the running one, the package had to be
installed *before* noble's HWE kernel put 7.0 headers there — leaving a 6.8
module that cannot load, and the in-tree 7.0 driver as the only thing that
could bind. That driver rejects the device.

On resolute none of that applies. The cloud image already boots 7.0, the 31.50
`amdgpu-dkms` is a 26.04 package that builds against it, and provisioning does
the ordinary thing: kernel and headers first, then DKMS, then the atomics patch,
then a rebuild for both installed kernels. `/etc/dkms/no-autoinstall-errors` is
**not** written on resolute — a failing amdgpu build for a future kernel is a
real regression there and should stop the install that caused it. The inverted
order and that flag file both survive in
[`provision/rocjitsu.sh`](../provision/rocjitsu.sh) behind `RELEASE = noble`,
for reference rather than for use.

qemu-minimal's `ansible/playbooks/vm-rocjitsu.yml` selects
`linux-generic-hwe-24.04` or `-26.04` by release and otherwise leaves the order
to the `rocm_setup` role. On resolute that order is correct; on noble it is the
failure described above.

## Firmware is not baked in

Still not baked in, and now for a demonstrated reason rather than a suspected
one: **no public release carries gfx1250 firmware.**
`amdgpu-dkms-firmware 1:31.50.0.0.31500000` — the newest driver tree with a
resolute suite — ships 683 files and not one `gc_12_1_0`, `sdma_7_1_0` or
`psp_15_0_8_toc_1.bin` among them. Ubuntu's `linux-firmware` has none either.
Upstream's `qemu-vfio.md` says to use "files from the same public driver/
firmware release", and for gfx1250 that release does not exist yet.

So the synthesised stubs remain the only way to boot the device, which is why
qemu-minimal generates them on the controller and why its playbook was pinned to
`…-ubuntu-rocm-rocjitsu:rocjitsu.730bc62` — the last tag whose image still had
the generator after upstream deleted
`emulation/rocjitsu/tools/vfio_guest_firmware.py`.

**That pin is no longer needed.** `ubuntu-rocm-rocjitsu` now ships
`/usr/local/bin/vfio_guest_firmware.py` again, fetched from that commit by SHA
(`rocjitsu_firmware_gen_commit` in `images.yml`, recorded in the
`…rocjitsu.firmware-gen-commit` label and in `rocjitsu-build.json`) while the
server itself keeps tracking the head of the series. Consumers can move back to
a current tag.

The generator emits five files:

```
gc_12_1_0_imu.bin  gc_12_1_0_mec.bin  gc_12_1_0_rlc_1.bin
gc_12_1_0_uni_mes.bin  sdma_7_1_0.bin
```

Two more are the caller's copies, because only the caller knows which MES path
its `amdgpu.ko` takes: `gc_12_1_0_mes.bin` and `gc_12_1_0_mes1.bin`, both copied
from `gc_12_1_0_uni_mes.bin`. The 7.1.3 DKMS driver additionally opens
`amdgpu/psp_15_0_8_toc_1.bin`, which nothing public provides and the generator
does not emit; public `linux-firmware` has only `psp_15_0_0_toc.bin` and
`psp_15_0_9_toc.bin`, which are different parts and must not be substituted.

Firmware and `ip_discovery.bin` stay in rocm-xio's runtime playbook, both of
them because they must match the consumer's rocjitsu pin rather than this
image's.

[`checks/rocjitsu.sh`](../checks/rocjitsu.sh) runs the inventory and prints what
is missing without failing. One note if you keep an assert on the rocm-xio side:
the pattern `gc_12_1_0|sdma_7_1_0|mes` is too loose — `mes` matches gc_11 and
gc_12_0 blobs that are present, so it can pass on a guest carrying none of the
gfx1250 firmware it was written to check for. The check here is scoped to
`gc_12_1_0|sdma_7_1_0` only.

## Autoload stays blacklisted

Deliberately, and belt-and-braces: `/etc/modprobe.d/amdgpu-blacklist.conf` plus
`modprobe.blacklist=amdgpu` on the kernel command line, the second so an
initramfs-driven load cannot slip in ahead of `/etc/modprobe.d`. Neither the
device nor its firmware exists until the consumer starts rocjitsu, and an
autoloaded copy wedges the guest: the in-tree module's `modprobe` returns 0
without rebinding, and unloading the DKMS one has been seen to GPF in
`kgd2kfd_device_exit`. The checks assert both, and that `amdgpu` is not loaded.

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

**`release: resolute`, the catalogue default again.** 26.04 boots 7.0 out of the
box and is the only release with an `amdgpu-dkms` that builds against it.

**`amdgpu_driver_version: 31.50`, not `latest`.** The `latest` symlink still
publishes `jammy` and `noble` only; `31.50` is the first version directory with
a `resolute` suite, and the `amdgpu-dkms` in it is `1:7.1.3.31500000`.
Provisioning probes `dists/<codename>/Release` before writing the apt source, so
a version without the guest's suite fails with both names in the message rather
than as a 404 several steps later.

## What the guest records about itself

`/etc/rocjitsu-guest.json`, written during provisioning:

```json
{
  "amdgpu_driver_repo_version": "31.50",
  "amdgpu_dkms_version": "1:7.1.3.31500000-2390945.26.04",
  "amdgpu_dkms_module": "7.1.3.31500000-2390945.26.04",
  "amdgpu_dkms_built_for_kernels": "7.0.0-30-generic 7.0.0-31-generic",
  "booted_kernel": "7.0.0-31-generic",
  "amdrocm_runtime_dev_version": "10.0.0-4",
  "rocm_stream": "therock",
  "kfd_atomics_patched": true,
  "kfd_atomics_patch_applies_to": "amdgpu-dkms source and the module built from it",
  "runtime_driver": "amdgpu-dkms 1:7.1.3.31500000-2390945.26.04, built for the booted kernel 7.0.0-31-generic",
  "amdgpu_autoload_blacklisted": true,
  "amdgpu_blacklisted_on_cmdline": true,
  "gfx1250_firmware": false,
  "ip_discovery_bin": false
}
```

`amdgpu_driver_repo_version` names a repository, not a build, which is why the
resolved package version is recorded next to it. The last two fields are false
on purpose and are the contract for what rocm-xio must still do at runtime.

## What rocm-xio still has to do at job time

1. Install the gfx1250 firmware stubs and `ip_discovery.bin` into
   `/lib/firmware/amdgpu/`, generated from the rocjitsu image it runs — both
   `vfio_guest_firmware.py` and `rj-ip-discovery` are in a current tag again —
   plus the two `uni_mes` copies.
2. `modprobe amdgpu` with the emulation parameters once the vfio-user server is
   serving. The image blacklists autoload but ships no helper; keep
   `amdgpu-probe` on the rocm-xio side, where the parameters belong.

Everything else in the current playbook — apt sources, keyrings, ROCm userspace,
the kernel, the DKMS install, the patch, the rebuild — is already in the disk.

## Publishing contract

Unchanged from `basic`: a `FROM scratch` payload whose `/output` carries the
qcow2, `id_rsa`, `id_rsa.pub` and `vm-info.json`. `vm-info.json` keeps
`vm_name`, `username`, `release` and `kernel_release`, and is
`schema_version: 4` — the only addition is `provisioning.provision`, naming the
in-guest script. Flavour-specific versions stay in the guest's own record rather
than leaking into this file.

Consume an explicit dated tag, never `:latest`.

## Open

- The image cannot be end-to-end tested in the build. The probe boot has no
  vfio-user device, so it asserts that the right driver is installed for the
  booted kernel, not that the emulated GPU comes up. Qualification is a boot
  under the rocjitsu stack: eight IP blocks, no vcn/jpeg failure, `amdgpu` bound
  under `/sys/bus/pci/drivers/amdgpu/`, and a KFD node present. A zero exit from
  `modprobe` proves none of that.
- `psp_15_0_8_toc_1.bin` has no public source. If the driver's PSP path turns
  out to be mandatory for this profile rather than best-effort, either the stub
  generator has to grow it or the device profile has to stop advertising that
  management processor.
- `test-vm-nvme.yml` is not on rocm-xio's default branch, so the runtime path it
  replaces has never run in CI either. Landing that workflow and this image
  together is worth doing in one go.
