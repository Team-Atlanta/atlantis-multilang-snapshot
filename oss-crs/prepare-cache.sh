#!/bin/bash
# Build all CRS base images and export to cache directory
# This is a one-time operation that takes 60-90 minutes
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CRS_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$CRS_ROOT"

echo "=============================================="
echo "=== Preparing CRS Image Cache ==="
echo "=============================================="
echo "CRS Root: $CRS_ROOT"
echo "Cache directory: $CRS_CACHE_DIR"
echo ""
echo "This process will:"
echo "  1. Build all CRS images via run.py build_crs --build-base-img"
echo "  2. Build joern service image"
echo "  3. Pull redis image"
echo "  4. Export all images to $CRS_CACHE_DIR"
echo ""
echo "Estimated time: 60-90 minutes"
echo "=============================================="
echo ""

# Create cache directory
mkdir -p "$CRS_CACHE_DIR"

# Step 1: Build all CRS images (includes base builder images)
echo "[1/4] Building all CRS images via run.py build_crs --build-base-img..."
echo "      This builds: multilang-clang, multilang-builder, multilang-builder-jvm,"
echo "                   crs-multilang, multilang-c-archive, multilang-jvm-archive, multilang-lsp-base"
python3 run.py build_crs --build-base-img --skip-symcc-verification

# Step 2: Build joern service image
echo ""
echo "[2/4] Building joern service image (multilang-runner-joern)..."
# Use --no-cache to avoid BuildKit cache corruption issues
docker build --no-cache -f joern/Dockerfile -t multilang-runner-joern .

# Step 3: Pull redis
echo ""
echo "[3/4] Pulling redis image..."
docker pull redis:latest

# Step 4: Export all images (compressed with gzip for ~50% space savings)
echo ""
echo "[4/4] Exporting images to $CRS_CACHE_DIR (compressed)..."

# Base builder images
echo "  Exporting base builder images..."
docker save multilang-clang | gzip > "$CRS_CACHE_DIR/multilang-clang.tar.gz"
docker save multilang-builder | gzip > "$CRS_CACHE_DIR/multilang-builder.tar.gz"
docker save multilang-builder-jvm | gzip > "$CRS_CACHE_DIR/multilang-builder-jvm.tar.gz"

# Archive images
echo "  Exporting archive images..."
docker save multilang-c-archive | gzip > "$CRS_CACHE_DIR/multilang-c-archive.tar.gz"
docker save multilang-jvm-archive | gzip > "$CRS_CACHE_DIR/multilang-jvm-archive.tar.gz"

# CRS runtime images
echo "  Exporting CRS runtime images..."
docker save crs-multilang | gzip > "$CRS_CACHE_DIR/crs-multilang.tar.gz"
docker save multilang-lsp-base | gzip > "$CRS_CACHE_DIR/multilang-lsp-base.tar.gz"
docker save multilang-runner-joern | gzip > "$CRS_CACHE_DIR/multilang-runner-joern.tar.gz"
docker save redis:latest | gzip > "$CRS_CACHE_DIR/redis.tar.gz"

# Create manifest with metadata
echo ""
echo "Creating manifest..."
cat > "$CRS_CACHE_DIR/manifest.json" << EOF
{
  "created": "$(date -Iseconds)",
  "crs_commit": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "images": {
    "multilang-clang": "$(docker inspect multilang-clang --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "multilang-builder": "$(docker inspect multilang-builder --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "multilang-builder-jvm": "$(docker inspect multilang-builder-jvm --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "multilang-c-archive": "$(docker inspect multilang-c-archive --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "multilang-jvm-archive": "$(docker inspect multilang-jvm-archive --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "crs-multilang": "$(docker inspect crs-multilang --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "multilang-lsp-base": "$(docker inspect multilang-lsp-base --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "multilang-runner-joern": "$(docker inspect multilang-runner-joern --format='{{.Id}}' 2>/dev/null || echo 'unknown')",
    "redis": "$(docker inspect redis:latest --format='{{.Id}}' 2>/dev/null || echo 'unknown')"
  }
}
EOF

echo ""
echo "=============================================="
echo "=== Cache prepared successfully ==="
echo "=============================================="
echo ""
echo "Cache contents:"
ls -lh "$CRS_CACHE_DIR"
echo ""
echo "Total cache size: $(du -sh "$CRS_CACHE_DIR" | cut -f1)"
echo ""
echo "You can now use build.sh with cached images."
echo "The cache will be mounted at /cache/images inside DinD containers."
