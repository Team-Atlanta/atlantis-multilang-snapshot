#!/bin/bash
set -eu

# CRS-Multilang Build Phase (DinD Mode)
#
# This script runs inside the DinD builder container. Key architecture points:
#
# 1. The Docker daemon runs INSIDE this container (DinD = Docker-in-Docker)
# 2. Nested Docker commands use CONTAINER paths (/artifacts, /work, /out)
# 3. These paths are mounted from the host by oss-crs compose.yaml.j2
# 4. No HOST_* environment variables are needed (unlike host_docker_builder mode)
#
# Volume mount chain:
#   Host: build/artifacts/.../  →  DinD: /artifacts/  →  Nested: /tarballs/
#   Host: build/out/.../        →  DinD: /out/
#   Host: build/work/.../       →  DinD: /work/

# Capture source directory before any cd commands
# oss-crs copies source to WORKDIR (/workspace) of the DinD builder
SOURCE_DIR="$(pwd)"

# Source config first for image arrays
source /crs-multilang/oss-crs-dind/config.sh

echo "=== CRS-Multilang Build Phase (DinD) ==="
echo "Using parent image: $PARENT_IMAGE"
echo "Project name: $PROJECT_NAME"
echo "Source directory: $SOURCE_DIR"
echo ""
echo "Docker data-root: /artifacts/docker-data (persisted to host)"

# Docker daemon is auto-started by cruizba/ubuntu-dind entrypoint
# With data-root=/artifacts/docker-data, Docker state persists to host
echo ""
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
    sleep 1
done
echo "Docker daemon ready"

# Create docker-data directory (Docker daemon may have already created it)
mkdir -p /artifacts/docker-data

cd /crs-multilang

# Step 1: Load CRS docker images from shared cache
echo ""
echo "[1/5] Loading CRS images..."

# Check if images are already available (from previous build or volume mode)
IMAGES_AVAILABLE=true
for img in "${DOCKER_IMAGES_BUILDER[@]}"; do
    if ! docker image inspect "$img" > /dev/null 2>&1; then
        IMAGES_AVAILABLE=false
        break
    fi
done

if [ "$IMAGES_AVAILABLE" = true ]; then
    echo "  Images already available (persisted from previous build or volume mode)"
    for img in "${DOCKER_IMAGES_BUILDER[@]}"; do
        echo "  ✓ $img"
    done
else
    echo "  Loading from tarballs (/cache/images/)..."
    /crs-multilang/oss-crs-dind/load-cache.sh all
fi

# Step 2: Load the project image from tarball (provided by oss-crs)
echo ""
echo "[2/5] Loading project image from /project-image.tar..."
docker load -i /project-image.tar

# Step 3: Prepare source tarball
# Following host_docker_builder pattern: only create repo.tar.gz manually
# Let run.py build handle project.tar.gz, fuzzers.tar.gz, and aixcc_conf.yaml
echo ""
echo "[3/5] Preparing source tarball..."
TARBALL_DIR=/artifacts/tarballs
mkdir -p "$TARBALL_DIR"

# Create repo.tar.gz from source directory (same as host_docker_builder)
REPO_TARBALL="$TARBALL_DIR/repo.tar.gz"
if [ ! -f "$REPO_TARBALL" ]; then
    echo "Creating repo.tar.gz from source directory..."
    tar --use-compress-program=pigz -cf "$REPO_TARBALL" -C "$SOURCE_DIR" .
    echo "Created $REPO_TARBALL"
else
    echo "repo.tar.gz already exists, skipping creation"
fi

# Step 4: Build fuzzers using run.py build
# run.py build handles: project.tar.gz, fuzzers.tar.gz, aixcc_conf.yaml (via create_conf)
echo ""
echo "[4/5] Building fuzzers via run.py build..."
# Disable buildx/buildkit - may have compatibility issues in nested DinD
export DOCKER_BUILDKIT=0
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir "$TARBALL_DIR" \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification \
    --start-other-services

# Step 5: Mark build as done
echo ""
echo "[5/5] Finalizing build..."
touch "$TARBALL_DIR/DONE"

# Note: No need to export images as tarballs anymore
# Docker data (including all images) persists in /artifacts/docker-data/
# The run phase will use the same Docker data directly

echo ""
echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
echo ""
echo "Tarballs in /artifacts/tarballs/:"
ls -la /artifacts/tarballs/
echo ""
echo "Docker data persisted in /artifacts/docker-data/"
echo "Size: $(du -sh /artifacts/docker-data 2>/dev/null | cut -f1 || echo 'calculating...')"
echo ""
echo "Available images for run phase:"
docker images --format "  ✓ {{.Repository}}:{{.Tag}} ({{.Size}})"
