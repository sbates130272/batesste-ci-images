# amdgpu DKMS patches for the `ernic-rocjitsu` guest flavour

`provision/ernic-rocjitsu.sh` applies these with `patch -p1` against the
amdgpu DKMS tree (`/usr/src/amdgpu-7.1.9-*`) before building it for the
mainline 7.2.4 kernel the flavour boots. They are applied in sorted order,
after the KFD atomics patch the provision script carries inline.

`checks/ernic-rocjitsu.sh` greps the installed source for a marker from each
one, so a driver bump that silently drops a hunk fails the image build rather
than the consumer's job.

They arrived here from hipObject's `ci/ernic/patches/amdgpu/`, where they were
scp'd into the guest at job time. That directory and the workflow step that
used it go away once this flavour is published.

`0003` is **not in this directory**. It lives in
[`assets/shared/patches/amdgpu/`](../../../shared/README.md) and is copied into
both this flavour's payload and the `rocjitsu` flavour's by the Dockerfile,
because it is needed by any guest that runs a DKMS amdgpu under rocjitsu and a
patch applied to one guest and not the other is a driver that oopses in only
one lane. It is still documented below, and it still arrives at
`/tmp/payload/patches/amdgpu/0003-…` with the same name and number — nothing in
the provision script changes.

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
