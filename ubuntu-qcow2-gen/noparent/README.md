# `noparent`

Deliberately empty. This directory is the `parentguest` build context for every
guest flavour that builds its own disk rather than deriving one.

`ubuntu-qcow2-gen/Dockerfile`'s stage phase bind-mounts `parentguest` at
`/parent`, and `build-vm.sh` decides what to do by looking for
`/parent/output/<vm-name>.qcow2`:

* a **derived** flavour gets the parent flavour's target as that context, finds
  the payload, and adopts it -- skipping `gen-vm`, the kernel layer and the whole
  provision phase;
* every other flavour gets *this* directory, finds nothing, and builds the
  guest from the cloud image as it always has.

The context has to be defined either way, because a `--mount=from=` naming a
context that does not exist is a build error. An empty directory is the
cheapest thing that satisfies it and the only one that cannot accidentally
contain a disk image.

A bind mount rather than a `COPY --from`: `COPY --from=parentguest /output/`
against a context with no `/output` in it fails, which would make the
non-derived case impossible to build. Mounting a directory with nothing in it is
simply an empty `/parent`.

Which flavour derives from which is declared in `images.yml` as
`guest_parent_variant`, and wired into bake by `ci-images-tool.py`. See
`ernic-rocjitsu-slim`.

A derived flavour also lands here when `build-contexts --standalone` is
used, which is what the Dockerfile Test workflow passes. That job builds
one target at a time, so the parent is not available to hand over: a fork
PR cannot resolve its Docker Hub ref at all, and adopting a published
payload would test the derived recipe against whatever was released last
rather than against the pull request. It builds its own guest there
instead, and the bake builds are what exercise adoption.
