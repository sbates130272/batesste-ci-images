ARG BASE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-base:latest
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# libvfio-user's own build deps; the C toolchain, cmake, ninja and pkg-config
# come from the base image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    meson \
    libglib2.0-dev \
    libjson-c-dev \
    libcmocka-dev

ARG LIBVFIO_USER_REPO=https://gitlab.com/qemu-project/libvfio-user.git
ARG LIBVFIO_USER_COMMIT

# The pin(s) above carry no default on purpose -- images.yml is the only place
# a pin is written. See "Why the Dockerfiles have no pin defaults" in the
# README. An undefaulted ARG is empty rather than an error, so this asserts.
RUN : "${LIBVFIO_USER_COMMIT:?set from images.yml by ci-images-tool.py; pass --build-arg LIBVFIO_USER_COMMIT=... for a bare docker build}"
ARG CACHE_BUST=

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/libvfio_user_cache_bust.txt

WORKDIR /build

# Installed under /usr/local so both downstream images (qemu and rocm-ernic)
# see the same prefix they used to build for themselves.
#
# --buildtype=release, which this did not pass before. libvfio-user's own
# meson.build sets `default_options: ['buildtype=debug', ...]`, so an
# unqualified `meson setup` produced an -O0 build -- and that is the
# libvfio-user.so every consumer of this image links, QEMU and rocm-ernic
# included, which is to say the vfio-user data path of every stack this
# repository publishes. Shipping the unoptimised build of a transport library
# was not a decision anyone took; it was the upstream default going unnoticed.
#
# It also removes the -Werror that broke this image on 26.04. meson.build:55
# adds -Werror only `if opt_debug`, so release drops it at the source rather
# than by suppressing a warning: Ubuntu 26.04 ships cmocka 2.0.2 where 24.04
# had 1.1.7, and 2.0 deprecated expect_check, which test/unit-tests.c still
# uses. Those four deprecations are now warnings and the tests still build. If
# a future pin needs -Werror back for the library proper, that is a separate
# flag, not a return to buildtype=debug.
#
# What this does NOT do is compile out assertions. meson's b_ndebug defaults to
# false, so release here means -O3 with asserts still live -- worth knowing,
# because "release" usually implies otherwise and a consumer debugging a vfu_*
# abort should not be told the checks are gone. -gdwarf-4 also survives, since
# it comes from default_options c_args and nothing here overrides c_args; that
# flag is upstream's workaround for clang with dwarf-5 breaking valgrind.
RUN git clone --filter=blob:none \
    "${LIBVFIO_USER_REPO}" \
    /build/libvfio-user && \
    cd /build/libvfio-user && \
    git checkout "${LIBVFIO_USER_COMMIT}" && \
    git rev-parse HEAD \
        > /usr/local/share/libvfio-user-commit.txt && \
    meson setup build --prefix=/usr/local --buildtype=release && \
    ninja -C build && \
    ninja -C build install && \
    ldconfig && \
    rm -rf /build/libvfio-user

CMD ["cat", "/usr/local/share/libvfio-user-commit.txt"]
