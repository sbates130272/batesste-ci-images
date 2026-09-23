# Shared guest assets

Files here are copied into **more than one** flavour's payload. The Dockerfile
does that copy, per flavour and by name, so `assets/shared` is never itself a
flavour and `build-vm.sh` never looks for it — a guest sees the contents at
`/tmp/payload`, exactly as if they had been checked in under its own directory.

One copy in the repo rather than one per flavour, because both of these are
things that must not drift between the two guests that carry a patched
`amdgpu-dkms`: a patch that is applied to one and not the other is a driver
that oopses in only one lane, and that is precisely the bug this directory was
created in response to.

| File | Goes to | Why it is shared |
| --- | --- | --- |
| `amdgpu-probe` | `rocjitsu`, `ernic-rocjitsu` | The emulation parameters belong with the driver build, and both flavours build the same driver. |
| `patches/amdgpu/0003-amdgpu-ras-guard-vbios-query.patch` | `rocjitsu`, `ernic-rocjitsu` | Always needed under rocjitsu, on any kernel — see [the patch notes](../ernic-rocjitsu/patches/amdgpu/README.md#0003-amdgpu-ras-guard-vbios-query). |

The `0003-` prefix is kept in both flavours even though `rocjitsu` applies no
`0001` or `0002`. The number is part of the patch's identity — it is what the
guest records in `amdgpu_patches` — not a position in a sequence.

Adding a file here does nothing on its own. Wire it up with a `COPY` in
[`../../Dockerfile`](../../Dockerfile) for each flavour that should receive it.
