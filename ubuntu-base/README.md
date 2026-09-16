# ubuntu-base

Shared Ubuntu foundation for every image in this collection.

## Overview

Every other `batesste-ci-images` image is built `FROM` this one. It exists so
the things they all need are installed, configured and cached exactly once:

- a C/C++ toolchain and the build tools shared across the collection
  (`build-essential`, `cmake`, `ninja-build`, `ccache`, `pkg-config`)
- `git`, `curl` and `wget`, tuned for large clones and downloads through a
  corporate proxy
- CA certificates, including AMD's root CA when the build context provides it
- `unattended-upgrades` removed and the periodic apt timers disabled, so an
  automatic update can never take the apt lock mid-build

The bar for adding to this image is deliberately high: everything here is paid
for by all ten downstream images, so it holds only what at least three of them
already installed.

## Base image

- `ubuntu:24.04`

The `FROM` line is a literal rather than an `ARG`. `ci-images-tool.py` parses
it to derive the Ubuntu version in the tag, and turning it into a build arg
would change the first instruction of the image and invalidate every layer
below it on every build.

## apt caching

This image hands `.deb` retention to BuildKit cache mounts: it deletes
`/etc/apt/apt.conf.d/docker-clean` and sets `Keep-Downloaded-Packages "true"`.

That has a consequence for anything built on top. **Every apt step in a
downstream image must mount both cache directories**, or the downloaded
packages land in the image layer instead of the cache:

```dockerfile
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends ...
```

## Usage

Rarely run directly -- it is a base layer -- but it is a usable Ubuntu shell
with a working toolchain:

```bash
docker run --rm -it \
  docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
```

To layer on it, take the published tag as a build arg:

```dockerfile
ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
FROM ${BASE_IMAGE}
```

`ci-images-tool.py` fills `BASE_IMAGE` in automatically for any image that
declares `base: ubuntu-base` in [`images.yml`](../images.yml).

## Tags

The tag variant for this image is the Ubuntu release it was built from, for
example `ubuntu24.04`. See the repository
[README](../README.md) for the full tag scheme.
