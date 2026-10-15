# Tooling for `ci-images-tool.py verify`: libguestfs, so a guest qcow2 can be
# read without booting it and without root.
#
# Local only. This is never pushed, never referenced by images.yml and never
# layered on by anything -- it exists so that verification needs nothing
# installed on the host or on a runner. ci-images-tool.py builds it on first
# use and Docker caches it thereafter.
#
# Named *.Dockerfile rather than Dockerfile on purpose: both
# scripts/check-readme-structure.sh and the hadolint lane select on
# `-maxdepth 2 -name Dockerfile`, and this is not an image directory -- it has
# no README, no images.yml entry and nothing to publish.
#
# linux-image-amd64 is not decoration. libguestfs boots a small appliance to
# do the reading, supermin builds that appliance out of the packages installed
# here, and without a kernel there is nothing to build it from.
FROM debian:13

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libguestfs-tools \
        linux-image-amd64 \
    && rm -rf /var/lib/apt/lists/*

# The appliance wants somewhere to cache itself; a fixed path keeps that
# inside the image's own layer rather than $HOME of whoever runs it.
ENV LIBGUESTFS_CACHEDIR=/var/tmp
