ARG BASE_IMAGE=docker.io/batesste/batesste-ci-images-ubuntu-base:latest
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
ARG LIBVFIO_USER_COMMIT=323f4cb6cddc3713fb7aebe44436f28b28b5413a
ARG CACHE_BUST=

RUN echo "Cache bust: ${CACHE_BUST:-none}" > /tmp/libvfio_user_cache_bust.txt

WORKDIR /build

# Installed under /usr/local so both downstream images (qemu and rocm-ernic)
# see the same prefix they used to build for themselves.
RUN git clone --filter=blob:none \
    "${LIBVFIO_USER_REPO}" \
    /build/libvfio-user && \
    cd /build/libvfio-user && \
    git checkout "${LIBVFIO_USER_COMMIT}" && \
    git rev-parse HEAD \
        > /usr/local/share/libvfio-user-commit.txt && \
    meson setup build --prefix=/usr/local && \
    ninja -C build && \
    ninja -C build install && \
    ldconfig && \
    rm -rf /build/libvfio-user

CMD ["cat", "/usr/local/share/libvfio-user-commit.txt"]
