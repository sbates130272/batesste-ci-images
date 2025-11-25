#!/bin/bash
#
# build-and-push.sh
#
# Script to build Docker image and optionally push to OCI registry
# Usage: build-and-push.sh [IMAGE_NAME] [--password-file FILE]
#   IMAGE_NAME: Name of the image directory (e.g., ubuntu-qemu-libvfio-user)
#               If not provided, builds all images
#   --password-file FILE: Path to file containing registry password
#                         (alternative to REGISTRY_PASSWORD env var)
#
# Password can be provided via:
#   - REGISTRY_PASSWORD environment variable (direct password or file path)
#   - REGISTRY_PASSWORD_FILE environment variable (file path)
#   - --password-file command line option
#   If REGISTRY_PASSWORD points to an existing file, it will be read as a file
#

set -e

# Source environment variables from .env if it exists
# Check multiple locations: local .env, then system-wide config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' "${SCRIPT_DIR}/.env" | xargs)
elif [ -f .env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' .env | xargs)
elif [ -f /etc/batesste-ci-images/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/batesste-ci-images/.env | xargs)
fi

# Parse command line arguments
IMAGE_NAME_ARG=""
PASSWORD_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --password-file)
            PASSWORD_FILE="$2"
            shift 2
            ;;
        --password-file=*)
            PASSWORD_FILE="${1#*=}"
            shift
            ;;
        *)
            if [ -z "$IMAGE_NAME_ARG" ]; then
                IMAGE_NAME_ARG="$1"
            fi
            shift
            ;;
    esac
done

# Set defaults
IMAGE_TAG=${IMAGE_TAG:-latest}
REGISTRY=${REGISTRY:-docker.io}
REGISTRY_USERNAME=${REGISTRY_USERNAME:-}
REGISTRY_PASSWORD=${REGISTRY_PASSWORD:-}
REGISTRY_PASSWORD_FILE=${REGISTRY_PASSWORD_FILE:-}
QEMU_COMMIT=${QEMU_COMMIT:-HEAD}
LIBVFIO_USER_COMMIT=${LIBVFIO_USER_COMMIT:-HEAD}

# Determine WORKDIR: use script directory if WORKDIR not set or doesn't exist
# (SCRIPT_DIR already set above)
if [ -z "${WORKDIR}" ]; then
    WORKDIR="${SCRIPT_DIR}"
elif [ ! -d "${WORKDIR}" ]; then
    echo "Warning: WORKDIR ${WORKDIR} does not exist, using script directory: ${SCRIPT_DIR}"
    WORKDIR="${SCRIPT_DIR}"
fi

# Determine password source: command line > env file > env direct
if [ -n "${PASSWORD_FILE}" ]; then
    REGISTRY_PASSWORD_FILE="${PASSWORD_FILE}"
elif [ -z "${REGISTRY_PASSWORD_FILE}" ] && [ -n "${REGISTRY_PASSWORD}" ]; then
    # Check if REGISTRY_PASSWORD is a file path
    if [ -f "${REGISTRY_PASSWORD}" ]; then
        REGISTRY_PASSWORD_FILE="${REGISTRY_PASSWORD}"
        REGISTRY_PASSWORD=""
    fi
fi

# Read password from file if specified
if [ -n "${REGISTRY_PASSWORD_FILE}" ]; then
    if [ ! -f "${REGISTRY_PASSWORD_FILE}" ]; then
        echo "Error: Password file not found: ${REGISTRY_PASSWORD_FILE}"
        exit 1
    fi
    REGISTRY_PASSWORD=$(cat "${REGISTRY_PASSWORD_FILE}" | tr -d '\n\r')
fi

cd "${WORKDIR}" || exit 1

# Get image name from argument or build all
if [ -n "${IMAGE_NAME_ARG}" ]; then
    IMAGE_DIRS=("${IMAGE_NAME_ARG}")
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

    # Construct image name: if REGISTRY_IMAGE contains /, use as-is,
    # otherwise prepend REGISTRY_USERNAME if available
    if [ -n "${REGISTRY_IMAGE}" ]; then
        if [[ "${REGISTRY_IMAGE}" == */* ]]; then
            # Already contains username/repo format
            IMAGE_NAME=${REGISTRY_IMAGE}-${IMAGE_DIR}
        elif [ -n "${REGISTRY_USERNAME}" ]; then
            # Prepend username
            IMAGE_NAME=${REGISTRY_USERNAME}/${REGISTRY_IMAGE}-${IMAGE_DIR}
        else
            # No username available, use as-is (may fail for Docker Hub)
            IMAGE_NAME=${REGISTRY_IMAGE}-${IMAGE_DIR}
        fi
    else
        # Default: use username if available, otherwise just repo name
        if [ -n "${REGISTRY_USERNAME}" ]; then
            IMAGE_NAME=${REGISTRY_USERNAME}/batesste-ci-images-${IMAGE_DIR}
        else
            IMAGE_NAME=batesste-ci-images-${IMAGE_DIR}
        fi
    fi
    
    echo "=== Building Docker Image ==="
    echo "Image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    echo "Directory: ${IMAGE_DIR}"
    echo "QEMU Commit: ${QEMU_COMMIT}"
    if [ -n "${LIBVFIO_USER_COMMIT}" ]; then
        echo "libvfio-user Commit: ${LIBVFIO_USER_COMMIT}"
    fi

    # Build the Docker image
    # Pass build args that may be used by some images
    # shellcheck disable=SC2086
    docker buildx build \
        --build-arg QEMU_COMMIT="${QEMU_COMMIT}" \
        --build-arg LIBVFIO_USER_COMMIT="${LIBVFIO_USER_COMMIT}" \
        --build-arg QEMU_MINIMAL_REPO="${QEMU_MINIMAL_REPO:-}" \
        --build-arg QEMU_MINIMAL_COMMIT="${QEMU_MINIMAL_COMMIT:-}" \
        --build-arg USERNAME="${USERNAME:-batesste}" \
        --build-arg VM_NAME="${VM_NAME:-}" \
        --build-arg PASSWORD="${PASSWORD:-changeme}" \
        --build-arg RELEASE="${RELEASE:-noble}" \
        --build-arg ARCH="${ARCH:-amd64}" \
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

