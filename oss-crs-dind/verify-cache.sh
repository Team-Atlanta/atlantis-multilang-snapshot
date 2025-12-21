#!/bin/bash
# Verify CRS images are available for DinD
#
# Checks:
# 1. Host Docker images (primary - used via overlayfs)
# 2. Tarball cache (fallback - for distribution/offline use)
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Use DOCKER_IMAGES_ALL from config.sh

echo "=============================================="
echo "=== CRS Image Verification ==="
echo "=============================================="
echo ""

#
# Check 1: Host Docker images (primary)
#
echo "=== Host Docker Images ==="
echo "Checking images in host Docker daemon..."
echo ""

docker_found=0
docker_missing=0
for img in "${DOCKER_IMAGES_ALL[@]}"; do
    if docker image inspect "$img" > /dev/null 2>&1; then
        size=$(docker image inspect "$img" --format '{{.Size}}' | numfmt --to=iec 2>/dev/null || echo "?")
        echo "  ✓ $img ($size)"
        docker_found=$((docker_found + 1))
    else
        echo "  ✗ $img (MISSING)"
        docker_missing=$((docker_missing + 1))
    fi
done

echo ""
echo "Host Docker: $docker_found found, $docker_missing missing"

#
# Check 2: Tarball cache (fallback)
#
echo ""
echo "=== Tarball Cache (Fallback) ==="
if [ -d "$CRS_CACHE_DIR" ]; then
    echo "Checking tarballs at: $CRS_CACHE_DIR"
    echo ""

    tarball_found=0
    tarball_missing=0
    for img in "${REQUIRED_IMAGES[@]}"; do
        img_base="${img%.tar.gz}"
        img_base="${img_base%.tar}"

        if [ -f "$CRS_CACHE_DIR/${img_base}.tar.gz" ]; then
            size=$(ls -lh "$CRS_CACHE_DIR/${img_base}.tar.gz" | awk '{print $5}')
            echo "  ✓ ${img_base}.tar.gz ($size)"
            tarball_found=$((tarball_found + 1))
        elif [ -f "$CRS_CACHE_DIR/${img_base}.tar" ]; then
            size=$(ls -lh "$CRS_CACHE_DIR/${img_base}.tar" | awk '{print $5}')
            echo "  ✓ ${img_base}.tar ($size)"
            tarball_found=$((tarball_found + 1))
        else
            echo "  ✗ $img_base (MISSING)"
            tarball_missing=$((tarball_missing + 1))
        fi
    done

    echo ""
    echo "Tarballs: $tarball_found found, $tarball_missing missing"
else
    echo "Tarball cache not found at: $CRS_CACHE_DIR"
    echo "Run ./prepare-cache.sh --tarballs to create it (optional)."
    tarball_found=0
    tarball_missing=${#REQUIRED_IMAGES[@]}
fi

#
# Summary
#
echo ""
echo "=============================================="
echo "=== Summary ==="
echo "=============================================="

if [ "$docker_missing" -eq 0 ]; then
    echo "✓ Host Docker: READY (all $docker_found images available)"
    echo ""
    echo "DinD containers will mount /var/lib/docker via overlayfs."
    echo "Instant startup - no image loading needed!"
    echo ""
    echo "Add to .env:"
    echo "  HOST_DOCKER_DATA=/var/lib/docker"
elif [ "$tarball_found" -gt 0 ] && [ "$tarball_missing" -eq 0 ]; then
    echo "⚠ Host Docker: INCOMPLETE ($docker_missing missing)"
    echo "✓ Tarballs: READY (fallback available)"
    echo ""
    echo "DinD will load images from tarballs (slower startup)."
    echo "Run ./prepare-cache.sh to build missing images."
else
    echo "✗ Host Docker: INCOMPLETE ($docker_missing missing)"
    echo "✗ Tarballs: INCOMPLETE ($tarball_missing missing)"
    echo ""
    echo "ERROR: No complete image source available."
    echo "Run ./prepare-cache.sh to build all required images."
    exit 1
fi
