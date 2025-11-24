#!/bin/bash
#
# build-and-push.sh
#
# Script to build Docker image and optionally push to OCI registry
# Usage: build-and-push.sh [IMAGE_NAME]
#   IMAGE_NAME: Name of the image directory (e.g., qemu-libvfio-user)
#               If not provided, builds all images
#

set -e

# Source environment variables from .env if it exists
if [ -f /etc/batesste-ci-images/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/batesste-ci-images/.env | xargs)
fi

# Set defaults
IMAGE_TAG=${IMAGE_TAG:-latest}
REGISTRY=${REGISTRY:-docker.io}
REGISTRY_USERNAME=${REGISTRY_USERNAME:-}
REGISTRY_PASSWORD=${REGISTRY_PASSWORD:-}
QEMU_COMMIT=${QEMU_COMMIT:-HEAD}
WORKDIR=${WORKDIR:-/opt/batesste-ci-images}

cd "${WORKDIR}" || exit 1

# Get image name from argument or build all
if [ -n "$1" ]; then
    IMAGE_DIRS=("$1")
else
    # Find all directories with Dockerfiles
    mapfile -t IMAGE_DIRS < <(find . -maxdepth 2 -name "Dockerfile" \
        -type f | sed 's|^\./||' | sed 's|/Dockerfile$||' | sort)
fi

# Ensure buildx is available
if ! docker buildx version > /dev/null 2>&1; then
    echo "Error: docker buildx is not available"
    exit 1
fi

# Create buildx builder if it doesn't exist
docker buildx create --name builder --use 2>/dev/null || \
    docker buildx use builder 2>/dev/null || true

# Login to registry if credentials are provided
if [ -n "${REGISTRY_USERNAME}" ] && [ -n "${REGISTRY_PASSWORD}" ]; then
    echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY}" \
        --username "${REGISTRY_USERNAME}" \
        --password-stdin
fi

# Build each image
for IMAGE_DIR in "${IMAGE_DIRS[@]}"; do
    if [ ! -f "${IMAGE_DIR}/Dockerfile" ]; then
        echo "Error: Dockerfile not found in ${IMAGE_DIR}"
        continue
    fi

    IMAGE_NAME=${REGISTRY_IMAGE:-batesste-ci-images}-${IMAGE_DIR}
    
    echo "=== Building Docker Image ==="
    echo "Image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    echo "Directory: ${IMAGE_DIR}"
    echo "QEMU Commit: ${QEMU_COMMIT}"

    # Build the Docker image
    docker buildx build \
        --build-arg QEMU_COMMIT="${QEMU_COMMIT}" \
        --tag "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" \
        --tag "${REGISTRY}/${IMAGE_NAME}:latest" \
        --load \
        -f "${IMAGE_DIR}/Dockerfile" \
        "${IMAGE_DIR}"

    # Push to registry if credentials are provided
    if [ -n "${REGISTRY_USERNAME}" ] && [ -n "${REGISTRY_PASSWORD}" ]; then
        echo "=== Pushing to Registry ==="
        docker push "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        docker push "${REGISTRY}/${IMAGE_NAME}:latest"
        
        echo "Image pushed successfully to \
            ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    else
        echo "Registry credentials not provided, skipping push"
    fi

    echo "=== Build Complete for ${IMAGE_DIR} ==="
done

