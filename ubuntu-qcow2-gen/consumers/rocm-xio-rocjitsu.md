# Guest image request: ROCm/rocm-xio, rocjitsu emulated GPU

Status: **image built and published, now on resolute.** The earlier noble build
carried a DKMS module that could never load; this one carries the driver that
does. Read [Which driver actually loads](#which-driver-actually-loads) and
[Firmware](#firmware-is-mostly-baked-in-now) before removing anything from
rocm-xio's runtime playbook — that section has changed, and it removes a step.

## What was asked for

rocm-xio's `test-vm-nvme` workflow installs ROCm userspace and builds
`amdgpu-dkms` over SSH at job time, which costs the better part of an hour on
every run. The ask was to move that into the guest disk, following the `ionic`
flavour's shape.

| # | Asked for | Landed |
| --- | --- | --- |
| 1 | ROCm userspace from the `therock` stream: `libstdc++-14-dev`, `amdrocm-runtime-dev`, `amdrocm-blas-dev` | yes — but see [BLAS](#amdrocm-blas-dev-is-headers-only) |
| 2 | `amdgpu-dkms` built against the guest kernel, KFD atomics patch applied first | yes, since the move to resolute |
| 3 | gfx1250 firmware present under `/lib/firmware`, asserted in the checks | **mostly yes now** — see [Firmware](#firmware-is-mostly-baked-in-now) |
| 4 | `blacklist amdgpu` in `/etc/modprobe.d/` | yes, plus `modprobe.blacklist=amdgpu` on the kernel cmdline |

The "nice to have" list — `build-essential`, `cmake`, `git`, `pciutils`,
`nvme-cli` — is in, along with the rest of rocm-xio's build dependencies.

Everything on the "do not want" list stays out except one item: no
`ip_discovery.bin`, no passwordless sudo. `amdgpu-probe` **is** now installed at
`/usr/local/bin/amdgpu-probe` — see
[The probe helper](#the-probe-helper-is-in-after-all).

## Which driver actually loads

`amdgpu-dkms 1:7.1.9.31600000`, built for the kernel the guest boots
(`7.0.0-31-generic`), carrying the KFD atomics patch in the module itself and
not only in its source tree. `modprobe amdgpu` resolves to
`/lib/modules/<kver>/updates/dkms/amdgpu.ko`, ahead of the in-tree module, and
`checks/rocjitsu.sh` asserts exactly that: `dkms status amdgpu -k "$(uname -r)"`
reporting `installed`, and `modinfo -n amdgpu` resolving under `updates/dkms`.

The one known-good hand-built guest was a 7.1.3 of the same lineage
(`[drm] amdgpu version: 7.1.3.31500000`), and it enumerates eight IP blocks with
psp/smu/mes present. It contains the UMSCH HW IP enumeration
(`4e07da515d1c`) that upstream names as the fix for

```text
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

On resolute none of that applies. The cloud image already boots 7.0, the 31.60
`amdgpu-dkms` is a 26.04 package that builds against it, and provisioning does
the ordinary thing: kernel and headers first, then DKMS, then the atomics patch,
then a rebuild for the kernel that boots (and for the provisioning kernel too,
when the HWE metapackage moves the guest off it). `/etc/dkms/no-autoinstall-errors` is
**not** written on resolute — a failing amdgpu build for a future kernel is a
real regression there and should stop the install that caused it. The inverted
order and that flag file both survive in
[`provision/rocjitsu.sh`](../provision/rocjitsu.sh) behind `RELEASE = noble`,
for reference rather than for use.

qemu-minimal's `ansible/playbooks/vm-rocjitsu.yml` selects
`linux-generic-hwe-24.04` or `-26.04` by release and otherwise leaves the order
to the `rocm_setup` role. On resolute that order is correct; on noble it is the
failure described above.

## Firmware is the consumer's job again

**This has changed back, and it is a breaking change for the runtime
playbook.** Briefly, the 31.60 driver tree packaged gfx1250 firmware — real
`gc_12_1_0_mec.bin`, `gc_12_1_0_mec_1.bin`, `gc_12_1_0_rlc.bin`,
`gc_12_1_0_rlc_1.bin`, `gc_12_1_0_uni_mes.bin` and `sdma_7_1_0.bin`, installed
by `amdgpu-dkms-firmware`, which `amdgpu-dkms` depends on — so the guest got
them with the driver, and this image baked them in.

**31.60 has been withdrawn from `repo.radeon.com`.** It is gone entirely, not
merely missing a suite. Of what the tree still publishes, only 31.30, 31.40,
31.40.1 and 31.50 serve `resolute` at all, and none of them package a single
`gc_12_1_0` or `sdma_7_1_0` blob — `amdgpu-dkms-firmware
1:31.50.0.0.31500000` ships 683 files and not one of them. This flavour is now
pinned to `31.50` and carries **no gfx1250 firmware at all**, which is where it
started.

So the whole set is the consumer's to install, as is `ip_discovery.bin`, and
both must match the rocjitsu pin you are running rather than this image's:

```bash
vfio_guest_firmware.py --set full --generation gfx1250 --output <dir>
rj-ip-discovery gfx1250
```

Two things to note about that call:

- **`--set full`, not the default `--set gap`.** `gap` omits exactly the blobs
  31.60 used to package, and nothing packages them now, so a `gap` set leaves
  the guest unbootable — `gc_12_1_0_imu.bin` is `AMDGPU_UCODE_REQUIRED` under
  the `amdgpu.fw_load_type=0` the vfio guest uses and the failure is fatal in
  `gfx_v12_1_init_microcode`, and the `mec`/`rlc` blobs it now also needs are
  absent.
- **`--generation gfx1250`** rather than `--config`, so no rocjitsu config file
  has to exist where the generator runs. This is what qemu-minimal's
  `vm-rocjitsu.yml` passes (PR #177).

Copy everything `manifest.json` names. For the full set
`packaged_by_driver_release` is empty, which is the accurate statement of what
the driver leaves to you.

### Pin note

qemu-minimal's playbook is pinned to `…-ubuntu-rocm-rocjitsu:rocjitsu.730bc62`,
the last tag whose image still had the generator after upstream deleted
`emulation/rocjitsu/tools/vfio_guest_firmware.py`. **That pin is stale and
should be dropped.** The generator is in every current tag — its builders are
vendored in this repo now rather than fetched from a deleted file — and
`rocjitsu.730bc62` predates the three upstream behaviours without which a guest
hangs rather than running a kernel.

### If you keep an assert on the rocm-xio side

The pattern `gc_12_1_0|sdma_7_1_0|mes` is too loose: `mes` matches gc_11 and
gc_12_0 blobs that every release ships, so it can pass on a guest carrying none
of the gfx1250 firmware it was written to check for. Scope it to
`gc_12_1_0|sdma_7_1_0`, and search `/lib/firmware/updates` as well as
`/lib/firmware` — the packaged blobs land under `updates/`.
[`checks/rocjitsu.sh`](../checks/rocjitsu.sh) scopes it that way. It no longer
asserts that any blob is *present*, because the image deliberately carries
none; it asserts that the driver declares gfx1250 firmware at all, which is the
half the image owns. Checking the files is yours to do after you have installed
them.

## Device node groups

**This has changed, and it removes a workaround.** `/dev/kfd` and
`/dev/dri/render*` are `root:render` 0660, and the login user used to be in
neither `render` nor `video` — so a payload run as that user got a HIP runtime
enumerating no agent and a `hipMalloc` returning `hipErrorNoDevice`, three lines
below a perfectly healthy KFD node in the same log. The workaround was to run
the payload under `sudo`.

The image now does `usermod -aG render,video` during provisioning, and
[`checks/rocjitsu.sh`](../checks/rocjitsu.sh) asserts both memberships. Running
under `sudo` is still harmless and still works, so nothing has to change on the
rocm-xio side — but it is no longer load-bearing, and dropping it makes the
failure mode visible if a future image regresses the groups.

Neither device node exists in the probe boot, so the checks assert the group
membership rather than an open on the node. `/etc/rocjitsu-guest.json` records
`"render_video_groups": true`; read that rather than assuming, since it is
absent in earlier builds of this image.

## Autoload stays blacklisted

Deliberately, and belt-and-braces: `/etc/modprobe.d/amdgpu-blacklist.conf` plus
`modprobe.blacklist=amdgpu` on the kernel command line, the second so an
initramfs-driven load cannot slip in ahead of `/etc/modprobe.d`. Neither the
device nor its firmware exists until the consumer starts rocjitsu, and an
autoloaded copy wedges the guest: the in-tree module's `modprobe` returns 0
without rebinding, and unloading the DKMS one has been seen to GPF in
`kgd2kfd_device_exit`. The checks assert both, and that `amdgpu` is not loaded.

## The probe helper is in, after all

`/usr/local/bin/amdgpu-probe`, a copy of the script qemu-minimal's
`vm-rocjitsu.yml` installs. This reverses the original "do not want": the
reasoning was that the parameters belong on the rocm-xio side, and that is still
true of *ownership* — nothing in the image runs it, the blacklist above stands
regardless, and you are free to ignore the file and pass your own parameters.

What changed is the cost of shipping nothing. This flavour does not run that
playbook, so a guest built here had no helper at all, and anyone reconstructing
the parameters by hand gets two of them wrong in ways that present as something
else:

```text
emu_mode=1 fw_load_type=0 discovery=2 ip_block_mask=0x7f vm_update_mode=3 \
    gpu_recovery=0 vramlimit=1024
```

`ip_block_mask` is `0x7f`, not the `0x3f` upstream's `qemu-vfio.md` quotes: this
DKMS build enumerates an extra `ras_v1_0` at index 5, pushing MES to 6, and
`gfx_v12_1` oopses in `gfx_v12_1_xcc_cp_resume` without it. `vramlimit` is 1024,
not 256 — it is the budget ROCr provisions queue scratch from, so 256 runs
scratch-free kernels fine and then hangs a private-segment dispatch forever.

The helper also refuses when `amdgpu` is already resident with the wrong
parameters, rather than exiting 0 having done nothing, which is what a bare
`modprobe` does on a loaded module.

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

**`amdgpu_driver_version: 31.50`, not `latest` and not `31.60`.** The `latest`
symlink still publishes `jammy` and `noble` only. `31.50` was the first version
directory with a `resolute` suite and is now the newest that still has one:
`31.60`, which this pinned while it shipped gfx1250 firmware, has been
withdrawn from `repo.radeon.com` altogether. Its `amdgpu-dkms` still builds
against 7.0, still carries GC 12.1.0 and the UMSCH HW IP enumeration, and still
carries the `kfd_device.c` line the atomics patch rewrites.

Do not "fix" this by taking a newer directory. The newer trees are precisely
the ones with no `resolute` suite — that is how 31.60's withdrawal surfaced, as
a failing `apt-get update` inside a published guest. Provisioning probes
`dists/<codename>/Release` before writing the apt source, so a version without
the guest's suite fails the build with both names in the message rather than as
a 404 several steps later, and `scripts/version-scrub.sh` warns daily if the
pinned tree stops serving the release.

**`guest_rocm_version: 10.0`.** The therock packages install under a versioned
component directory (`/opt/rocm/core-10.0`, not `/opt/rocm`), so `ROCM_PATH`
has to be named rather than assumed. It is composed into `ROCM_PATH` in
`images.yml` and written to `/etc/profile.d/rocm.sh` in the guest, so a login
shell gets `ROCM_PATH` and `$ROCM_PATH/bin` on `PATH` — previously neither was
set and nothing in ROCm was on `PATH`. Provisioning asserts the directory
exists, so a stale pin fails the build rather than shipping a dead `PATH`
entry.

## What the guest records about itself

`/etc/rocjitsu-guest.json`, written during provisioning:

```json
{
  "amdgpu_driver_repo_version": "31.50",
  "amdgpu_dkms_version": "1:7.1.9.31600000-2403767.26.04",
  "amdgpu_dkms_module": "7.1.9-2403767.26.04",
  "amdgpu_dkms_built_for_kernels": "7.0.0-31-generic",
  "booted_kernel": "7.0.0-31-generic",
  "amdrocm_runtime_dev_version": "10.0.0-4",
  "rocm_stream": "therock",
  "kfd_atomics_patched": true,
  "kfd_atomics_patch_applies_to": "amdgpu-dkms source and the module built from it",
  "amdgpu_patches": ["0003-amdgpu-ras-guard-vbios-query.patch:3f1c0b9a2e4d5678"],
  "runtime_driver": "amdgpu-dkms 1:7.1.9.31600000-2403767.26.04, built for the booted kernel 7.0.0-31-generic",
  "amdgpu_autoload_blacklisted": true,
  "amdgpu_blacklisted_on_cmdline": true,
  "amdgpu_probe_helper": "/usr/local/bin/amdgpu-probe",
  "render_video_groups": true,
  "amdgpu_dkms_firmware_version": "1:31.50.0.0.31500000-2403767.26.04",
  "gfx1250_firmware": "none -- generated by the consumer",
  "gfx1250_firmware_dir": "/lib/firmware/updates/amdgpu",
  "gfx1250_firmware_missing": ["the whole gfx1250 set"],
  "gfx1250_firmware_missing_source": "vfio_guest_firmware.py --set full --generation gfx1250, from the rocjitsu image the consumer runs",
  "ip_discovery_bin": false
}
```

`amdgpu_driver_repo_version` names a repository, not a build, which is why the
resolved package version is recorded next to it. `gfx1250_firmware` has been
`false`, then `"packaged"` while the 31.60 tree existed, and is now
`"none -- generated by the consumer"`; read it rather than assuming any of
them. `gfx1250_firmware_missing` and `ip_discovery_bin` are the contract for
what rocm-xio must still do at runtime, and
`gfx1250_firmware_missing_source` names the exact call.

`amdgpu_patches` lists every patch applied to the DKMS source beyond the
atomics one, each with the first 16 hex of its SHA-256, so a guest can be asked
what it was built from rather than inferred from a version number. It is new,
alongside `amdgpu_probe_helper`; both are absent from images built before this
change, so test for the key rather than assuming it.

## What rocm-xio still has to do at job time

1. Install everything `vfio_guest_firmware.py`'s manifest names into
   `/lib/firmware/amdgpu/` — `gc_12_1_0_imu.bin`, `ip_discovery.bin` and the
   two `uni_mes` aliases — generated from the rocjitsu image it runs. The rest
   of the gfx1250 firmware is already in the guest; do not overwrite it.
2. Load the driver once the vfio-user server is serving. The image blacklists
   autoload; `sudo amdgpu-probe` is now in the guest if you want it, or pass
   your own parameters — see
   [The probe helper](#the-probe-helper-is-in-after-all).

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
