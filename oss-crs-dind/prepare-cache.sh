#!/bin/bash
# Build CRS images for DinD usage and export as tarballs
#
# By default, this script:
# 1. Builds all CRS images
# 2. Exports them as .tar.gz files to cache/images/
#
# The tarballs are used by build.sh to load images into DinD containers.
# Docker data persists to /artifacts/docker-data/ so tarballs only need
# to be loaded once per project.
#
# Usage:
#   ./prepare-cache.sh              # Build images and export tarballs (default)
#   ./prepare-cache.sh --skip-build # Skip building, just export tarballs
#   ./prepare-cache.sh --only-build # Build only, don't export tarballs
#   ./prepare-cache.sh --volume     # Also create Docker volume (optional)
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CRS_ROOT="$(dirname "$SCRIPT_DIR")"

# DinD image for volume population
DIND_IMAGE="${DIND_IMAGE:-cruizba/ubuntu-dind:latest}"

# Parse arguments
SKIP_BUILD=false
EXPORT_TARBALLS=true  # Default: export tarballs
CREATE_VOLUME=false
for arg in "$@"; do
    case $arg in
        --skip-build)
            SKIP_BUILD=true
            ;;
        --only-build)
            EXPORT_TARBALLS=false
            ;;
        --tarballs)
            # Explicit flag (for backward compatibility)
            EXPORT_TARBALLS=true
            ;;
        --volume)
            CREATE_VOLUME=true
            ;;
        --all)
            EXPORT_TARBALLS=true
            CREATE_VOLUME=true
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-build  Skip building, just export tarballs"
            echo "  --only-build  Build only, don't export tarballs"
            echo "  --tarballs    Export tar.gz files (default, for backward compat)"
            echo "  --volume      Also create Docker volume (optional)"
            echo "  --all         Export tarballs and create volume"
            echo "  -h, --help    Show this help"
            echo ""
            echo "Default behavior: Build images and export tarballs to cache/images/"
            echo ""
            echo "Environment Variables:"
            echo "  CRS_CACHE_DIR     Directory for tarball cache (default: ./cache/images)"
            echo "  CRS_VOLUME_NAME   Docker volume name (default: crs-multilang-images)"
            exit 0
            ;;
    esac
done

echo "=============================================="
echo "=== Preparing CRS Images for DinD ==="
echo "=============================================="
echo "Build:    $([ "$SKIP_BUILD" = true ] && echo "skip" || echo "yes")"
echo "Tarballs: $([ "$EXPORT_TARBALLS" = true ] && echo "yes → $CRS_CACHE_DIR" || echo "no")"
echo "Volume:   $([ "$CREATE_VOLUME" = true ] && echo "yes ($CRS_VOLUME_NAME)" || echo "no")"
echo "=============================================="
echo ""

#
# Step 1: Build images (unless --skip-build)
#
if [ "$SKIP_BUILD" = false ]; then
    cd "$CRS_ROOT"

    echo "[1/3] Building CRS images..."
    uv run python run.py build_crs --build-base-img --skip-symcc-verification

    echo ""
    echo "[2/3] Building joern image..."
    docker build -f joern/Dockerfile -t multilang-runner-joern .

    echo ""
    echo "[3/3] Pulling redis..."
    docker pull redis:latest
fi

#
# Step 2: Verify images exist
#
echo ""
echo "Checking images..."
MISSING=false
FOUND=0
for img in "${DOCKER_IMAGES_ALL[@]}"; do
    if docker image inspect "$img" > /dev/null 2>&1; then
        size=$(docker image inspect "$img" --format '{{.Size}}' | numfmt --to=iec 2>/dev/null || echo "?")
        echo "  ✓ $img ($size)"
        FOUND=$((FOUND + 1))
    else
        echo "  ✗ $img (MISSING)"
        MISSING=true
    fi
done

if [ "$MISSING" = true ]; then
    echo ""
    echo "ERROR: Some images missing. Run without --skip-build first."
    exit 1
fi

#
# Step 3: Export tarballs (default behavior)
#
if [ "$EXPORT_TARBALLS" = true ]; then
    echo ""
    echo "=== Exporting tarballs ==="
    mkdir -p "$CRS_CACHE_DIR"

    for img in "${DOCKER_IMAGES_ALL[@]}"; do
        if docker image inspect "$img" > /dev/null 2>&1; then
            filename="${img%%:*}.tar.gz"
            echo "  Exporting $img → $filename"
            docker save "$img" | pigz > "$CRS_CACHE_DIR/$filename"
        fi
    done

    echo ""
    echo "Tarballs exported to: $CRS_CACHE_DIR"
    ls -lh "$CRS_CACHE_DIR"
fi

#
# Step 4: Create and populate Docker volume (optional)
#
if [ "$CREATE_VOLUME" = true ]; then
    echo ""
    echo "=== Creating Docker volume: $CRS_VOLUME_NAME ==="

    # Check if volume already exists
    if docker volume inspect "$CRS_VOLUME_NAME" > /dev/null 2>&1; then
        echo "Volume '$CRS_VOLUME_NAME' already exists."
        read -p "Recreate volume? This will delete existing data. [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Removing existing volume..."
            docker volume rm "$CRS_VOLUME_NAME" 2>/dev/null || true
        else
            echo "Keeping existing volume. Skipping volume creation."
            CREATE_VOLUME=false
        fi
    fi

    if [ "$CREATE_VOLUME" = true ]; then
        # Create the volume
        docker volume create "$CRS_VOLUME_NAME"
        echo "Volume created: $CRS_VOLUME_NAME"

        # Save images to temp directory
        echo ""
        echo "Saving images to temp directory..."
        TEMP_DIR=$(mktemp -d)
        trap "rm -rf $TEMP_DIR" EXIT

        for img in "${DOCKER_IMAGES_ALL[@]}"; do
            if docker image inspect "$img" > /dev/null 2>&1; then
                # Use simple filename (no colons)
                filename="${img//[:\/]/_}.tar"
                echo "  Saving $img → $filename"
                docker save -o "$TEMP_DIR/$filename" "$img"
            fi
        done

        # Load images into volume using DinD container
        echo ""
        echo "Loading images into volume (this may take a few minutes)..."
        docker run --privileged --rm \
            -v "$CRS_VOLUME_NAME":/var/lib/docker \
            -v "$TEMP_DIR":/images:ro \
            "$DIND_IMAGE" \
            sh -c '
                # Wait for Docker daemon to start
                echo "Waiting for Docker daemon..."
                while ! docker info > /dev/null 2>&1; do sleep 1; done
                echo "Docker daemon ready"

                # Load all images
                echo "Loading images..."
                for f in /images/*.tar; do
                    if [ -f "$f" ]; then
                        echo "  Loading $(basename "$f")..."
                        docker load -i "$f"
                    fi
                done

                # Show loaded images
                echo ""
                echo "Loaded images:"
                docker images
            '

        echo ""
        echo "Volume '$CRS_VOLUME_NAME' populated successfully!"
    fi
fi

#
# Done
#
echo ""
echo "=============================================="
echo "=== Done! ==="
echo "=============================================="
echo ""
echo "All $FOUND CRS images are available."
echo ""

if [ "$EXPORT_TARBALLS" = true ]; then
    echo "Tarballs exported to: $CRS_CACHE_DIR"
    echo ""
    echo "Configure oss-crs:"
    echo "  HOST_CACHE_DIR=$CRS_CACHE_DIR"
    echo ""
fi

if [ "$CREATE_VOLUME" = true ]; then
    echo "Docker volume created: $CRS_VOLUME_NAME"
    echo ""
fi
