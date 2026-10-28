# amdgpu DKMS patches for the rocjitsu guest flavours

Applied with `patch -p1` against the amdgpu DKMS tree
(`/usr/src/amdgpu-7.1.9-*`) before it is built, in sorted order, after the KFD
atomics patch the provision scripts carry inline.

Every flavour that builds a DKMS amdgpu to run under rocjitsu gets all of
them. `provision/rocjitsu.sh` and `provision/ernic-rocjitsu.sh` each read
`/tmp/payload/patches/amdgpu/`, and the Dockerfile grafts this directory onto
both payloads -- see the `COPY ... assets/shared/patches/` lines there.

They live here rather than under one flavour because a patch applied to one
guest and not the other is a driver that oopses in only one of them, which is
the hardest kind of difference to find. `0001` and `0002` were under
`assets/ernic-rocjitsu/` until 2026-10-28, when the `rocjitsu` flavour moved
to the same mainline 7.2.6 kernel and needed the same series.

  * `0001` -- the unreviewed KFD ptrace gate, needed from 7.2.
  * `0002` -- probe `panel_type` separately in the amdkcl configure tests.
  * `0003` -- guard the RAS VBIOS query. rocjitsu serves no option ROM
    (`rombar=0`), so `adev->mode_info.atom_context` is NULL and the unguarded
    query oopses in `amdgpu_atom_parse_data_header`. Needed on every kernel,
    not just 7.2.

`checks/rocjitsu.sh` and `checks/ernic-rocjitsu.sh` grep the installed source
for a marker from each one, so a driver bump that silently drops a hunk fails
the image build rather than the consumer's job.

## `0001-amdkfd-fail-closed-ptrace-gate-7.2` — **unreviewed**

**TODO(unreviewed): this patch changes a KFD security check and has not been
reviewed as policy.** It was written to make the build pass on 7.2 and nothing
more. The guest records this as `"kfd_ptrace_gate_reviewed": false` in
`/etc/ernic-rocjitsu-guest.json`, and it should stay false until someone who
owns that check signs off on it.

What it does: 7.2 moved dumpability and the exec-time `user_ns` off
`mm_struct` onto `task->exec_state`, and neither `task_exec_state_get_dumpable()`
nor `task_exec_state_rcu()` is exported, so an out-of-tree module cannot read
either. The patch version-gates the check and, on >= 7.2, requires
`CAP_SYS_PTRACE` unconditionally instead. It is argued to be strictly no weaker
than the in-tree gate — it only denies what that gate would allow — and <= 7.1
keeps the upstream logic verbatim. That argument is the thing wanting review.

This flavour is for emulated-device CI guests, not for anything holding real
user data, which is why it ships rather than blocks.

## `0002-amdkcl-probe-panel-type-separately`

Needed on any mainline kernel >= 6.19. `amdgpu_dm_set_panel_type()` is gated on
`HAVE_DRM_DISPLAY_INFO_AMD_VSDB`, whose probe cites a commit that *did* merge at
v6.19 — but the function body uses `display_info->panel_type` and
`DRM_MODE_PANEL_TYPE_LCD`, which are AMD-downstream only and never merged. The
patch adds `AC_AMDGPU_DRM_DISPLAY_INFO_PANEL_TYPE` and
`AC_AMDGPU_DRM_MODE_PANEL_TYPE_LCD` probes and guards both uses.

A plain bug, unrelated to emulation, and worth sending to AMD regardless of
this flavour.

## `0003-amdgpu-ras-guard-vbios-query`

Always needed under rocjitsu. rocjitsu serves no option ROM (`rombar=0`), so
`adev->mode_info.atom_context` is NULL;
`amdgpu_ras_query_ras_capablity_from_vbios()` dereferences it unconditionally
and the probe oopses in `amdgpu_atom_parse_data_header+0x9`. The patch adds the
NULL check to the condition that guards the call.
