# Guest image request: ROCm/rocm-ernic, ionic device mode

Status: **blocked on this repo** — `ubuntu-qcow2-gen@ionic` exists and its
packages and checks are in place, but no image has been published yet.

## What is needed

A guest qcow2 whose kernel is **>= 6.18**, because
`drivers/infiniband/hw/ionic` merged in 6.18. On an older guest the Ethernet
half of the driver builds and the RDMA half does not, which fails late and
unclearly.

`ubuntu-qcow2-gen@ionic` already targets this: guests default to resolute
(Linux 7.0) via `defaults.vars.release`, and
[`checks/ionic.sh`](../checks/ionic.sh) asserts the floor by comparing the
whole version tuple with `sort -V`.

## Consumers

Both are the *same* guest, and the second asserts on what the first built —
not two independent floors.

1. **Golden backing image.** `ernic_vm_release: noble` in
   `ansible/group_vars/all.yml`, consumed as `RELEASE:` when
   `ansible/playbooks/vm-create.yml` creates
   `<vm_name_base>-backing.qcow2`. noble is 6.8.
2. **`driver_ionic.yml`** in the `ernic_guest_setup` role asserts
   `ansible_kernel.split('-')[0] is version(ernic_ionic_min_kernel, '>=')`
   with `ernic_ionic_min_kernel: "6.18"`. This runs against the guest built
   in (1), so it fails on every default run today.

Setting `ernic_vm_release: resolute` satisfies both.

The assert itself is correct as written: `is version` compares properly, so
`7.0.0 >= 6.18` passes, and `.split('-')[0]` strips the `-<abi>-generic`
suffix. It does **not** need changing.

### Not a consumer

The `ionic-patches` job in `.github/workflows/driver-build.yml` only checks
that the pinned `IONIC_KERNEL_REF` still exists and that the patches still
apply. It deliberately does not build the modules, because hosted runners
lack >= 6.18 headers. It boots no guest and needs no image.

## What the ionic flavour pre-bakes

[`packages/ionic.txt`](../packages/ionic.txt) installs the toolchain, DKMS,
`linux-headers-generic` / `linux-modules-extra-generic`, the rdma-core v62
build dependencies, and distro rdma-core for `ibv_devinfo`.

The `ionic-ernic` DKMS modules are deliberately **not** built here — building
them from pinned upstream sources is what the consuming jobs exist to test.

Two caveats for the consumer side:

- 26.04's apt `rdma-core` predates `providers/ionic` (upstream v61), so a job
  needing `libionic*.so` must still build rdma-core from source over the top.
  That build overwrites dpkg-owned files under `/usr`, so hold or remove apt
  `rdma-core` / `libibverbs-dev` / `ibverbs-utils` afterwards, or a later
  `apt upgrade` reverts it.
- `IONIC_KERNEL_REF` is pinned at `v7.2.4` while the guest kernel is 7.0.
  Not guaranteed to compile; worth a dry run before the image is cut.

## Acceptance

1. `./ci-images-tool.py build ubuntu-qcow2-gen@ionic` passes, including the
   probe boot running `checks/ionic.sh`.
2. `vm-info.json` reports `kernel_release` >= 6.18 and `flavour: ionic`.
3. The image is published, and rocm-ernic consumes it instead of building a
   golden image of its own.

## Open

- `vm_playbook` is empty for this flavour. A `vm-ionic.yml` upstream in
  qemu-minimal — source-building rdma-core 62.0 and pre-seeding
  `/opt/ionic-src` — is an optimisation, not a prerequisite. Guest
  provisioning is owned upstream so it stays shared with the non-container
  `qemu-tool` workflows.
- rocm-ernic's brief assumed GitHub-hosted runners have no nested virt. For
  x86 `ubuntu-latest` that is wrong — `/dev/kvm` is present as `root:kvm
  0660`, which is why this repo's workflows carry a udev step. Running QEMU
  in a container needs `--device /dev/kvm` plus that group fix, not nested
  virt. Taking it would stop a 2-vCPU TCG guest eating their time budget.
  Boot mode is a consumer choice and does not gate this image.
