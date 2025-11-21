#!/bin/bash
#
# build-and-push.sh
#
# Script to build Docker image and optionally push to OCI registry
#

set -e

# Source environment variables from .env if it exists
if [ -f /etc/batesste-ci-images/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/batesste-ci-images/.env | xargs)
fi

# Set defaults
IMAGE_NAME=${REGISTRY_IMAGE:-batesste-ci-images}
IMAGE_TAG=${IMAGE_TAG:-latest}
REGISTRY=${REGISTRY:-docker.io}
REGISTRY_USERNAME=${REGISTRY_USERNAME:-}
REGISTRY_PASSWORD=${REGISTRY_PASSWORD:-}
QEMU_COMMIT=${QEMU_COMMIT:-HEAD}
WORKDIR=${WORKDIR:-/opt/batesste-ci-images}

cd "${WORKDIR}" || exit 1

echo "=== Building Docker Image ==="
echo "Image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
echo "QEMU Commit: ${QEMU_COMMIT}"

# Ensure buildx is available
if ! docker buildx version > /dev/null 2>&1; then
    echo "Error: docker buildx is not available"
    exit 1
fi

# Create buildx builder if it doesn't exist
docker buildx create --name builder --use 2>/dev/null || docker buildx use builder 2>/dev/null || true

# Build the Docker image
docker buildx build \
    --build-arg QEMU_COMMIT="${QEMU_COMMIT}" \
    --tag "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" \
    --tag "${REGISTRY}/${IMAGE_NAME}:latest" \
    --load \
    .

# Push to registry if credentials are provided
if [ -n "${REGISTRY_USERNAME}" ] && [ -n "${REGISTRY_PASSWORD}" ]; then
    echo "=== Pushing to Registry ==="
    echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY}" \
        --username "${REGISTRY_USERNAME}" \
        --password-stdin
    
    docker push "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    docker push "${REGISTRY}/${IMAGE_NAME}:latest"
    
    echo "Image pushed successfully to ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
    echo "Registry credentials not provided, skipping push"
fi

echo "=== Build Complete ==="

