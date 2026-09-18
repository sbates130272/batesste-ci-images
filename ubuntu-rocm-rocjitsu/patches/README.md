# Local patches against `ROCJITSU_COMMIT`

Applied by the Dockerfile in filename order with `git apply --3way`, against
`20d4ce1c` on `users/agutierr/gfx1250-vfio-compute-6`. Each patch carries its
own reasoning in its commit message; this file is the index and the policy.

Without them the image serves a vfio-user device that a guest cannot boot
`amdgpu` against, and cannot run a kernel needing private memory on if it did.
That is why `rocm-xio`'s `test-vm-nvme` had to pin a hand-built image rather
than a `batesste-ci-images-*` tag.

| # | Patch | Files | What it fixes |
| --- | --- | --- | --- |
| 0001 | `accept-gart-root-with-pde-flags` | `gpu_vm.cpp` +16/-4 | `valid_gart_config()` rejects any `PAGE_TABLE_BASE_ADDR` that is not 4 KiB aligned, but `amdgpu_gmc_pd_addr()` sets the PDE flag bits in its low bits, so a real root arrives as e.g. `0x6900005`. `publish_gart()` returns false, the GFXHUB acknowledge bit stays clear, and the guest dies with `Timeout waiting for VM flush ACK!`. Validates the masked address, which is what is actually dereferenced. |
| 0002 | `pass-through-out-of-aperture-gart-access` | `gpu_vm.cpp` +29/-2 | `Gfx12GartTranslator::translate()` faults out-of-aperture addresses. The driver's own page tables live in VRAM at `0x68ec000`, outside the aperture, so its SDMA page-table update faults, the fence never signals, and the guest hangs in `kfd_ioctl_acquire_vm` with `ring sdma0.0 timeout`. Restores the older pass-through. |
| 0003 | `bound-sdma-ring-by-gart-aperture-at-admission` | `gpu_vm.{cpp,h}`, `pci/sdma_block_model.cpp` +33 | 0002 removes a bound upstream asserts in `GpuDeviceSdma.RegisterBackedQueueRejectsAddressesOutsideTheGartAperture`, and that assertion is right. Re-enforces it at queue admission — the layer that can tell a ring fetch from an IB fetch — so the translator stays permissive and the upstream test passes unmodified. |
| 0004 | `align-gart-aperture-tests-with-driver-semantics` | `tests/gpu_vm_translation_test.cpp` +43/-8 | Restates the two expectations 0002 and 0003 change, and swaps the `page_table_base = 0x1001` rejection case for `GpuVmAcceptsAGartRootCarryingPdeFlagBits`. |
| 0005 | `request-scratch-backing-from-the-guest-runtime` | `command_processor.cpp` +177, `dispatch_entry.h` +13, `aql_packet_processor.h` +2 | The one that makes GPU dispatches run at all. On gfx12 ROCr allocates no scratch at queue creation and waits for the packet processor to ask via `queue_inactive_signal`. The CP never asks, `init_wavefront_regs()` gets `Faulted`, and any dispatch needing private memory hangs forever. |

Totals: 7 files, 313 insertions, 14 deletions.

0001–0004 fix a regression introduced *inside* the `-6` branch by `aac939813f`,
which grew `publish_gart()` a `valid_gart_config()` precondition. 0005 is not a
regression — it is a gap in the vfio-user path that older commits have too.

Note that 0004 only touches tests, and the image builds with
`-DBUILD_TESTING=OFF`. It is carried anyway so the series stays a coherent thing
to send upstream and so a `BUILD_TESTING=ON` build of this tree is not red.

## Policy

Keep this short. A patch that survives more than a couple of pin bumps belongs
upstream, not here. `scripts/version-scrub.sh` freezes `rocjitsu_commit` while
this directory is non-empty, precisely because a bump without a rebase is a red
build rather than a newer image — so every patch here is also holding the pin
back.

`NotesForRocjitsu.md` in the `vfio-rocjitsu` tree documents all nine defects
found on this path for the rocJITsu maintainers. When the series lands upstream,
this whole directory collapses back to a plain commit bump.

## Rebasing onto a newer pin

These are hand-written diffs, not `git format-patch` output: each carries a
`Subject:` line and a body but no `From:`/`Date:` headers, so `git am` aborts on
them with `empty ident name`. Apply them the way the Dockerfile does.

```bash
# in a rocm-systems checkout at the new commit
for p in ubuntu-rocm-rocjitsu/patches/*.patch; do git apply --3way "$p"; done
```

Fix any rejects, then re-export by hand, keeping each file's header block.
Re-exporting with `git format-patch --no-signature -5` instead is a worthwhile
upgrade -- it would add the `index` blob lines that 0005 lacks, which are what
stop git from 3-way merging that one -- but do it deliberately, since it
rewrites all five files.

Then move `rocjitsu_commit` in `images.yml` and the `ARG` in the Dockerfile
together, and re-prove it against a guest — see *Verifying a patched image*
in the image README. A green `docker build` is not evidence
these patches work; it only proves they applied.
