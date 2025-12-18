#!/bin/bash
# Verify all required cached images exist
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Verifying cache at: $CRS_CACHE_DIR"
echo ""

missing=0
found=0

# Check for images (support both .tar and .tar.gz)
for img in "${REQUIRED_IMAGES[@]}"; do
    # Try .tar.gz first, then .tar
    img_base="${img%.tar.gz}"
    img_base="${img_base%.tar}"

    if [ -f "$CRS_CACHE_DIR/${img_base}.tar.gz" ]; then
        size=$(ls -lh "$CRS_CACHE_DIR/${img_base}.tar.gz" | awk '{print $5}')
        echo "[OK] ${img_base}.tar.gz ($size)"
        found=$((found + 1))
    elif [ -f "$CRS_CACHE_DIR/${img_base}.tar" ]; then
        size=$(ls -lh "$CRS_CACHE_DIR/${img_base}.tar" | awk '{print $5}')
        echo "[OK] ${img_base}.tar ($size)"
        found=$((found + 1))
    else
        echo "[MISSING] $img_base"
        missing=$((missing + 1))
    fi
done

echo ""
echo "Summary: $found found, $missing missing"

if [ "$missing" -gt 0 ]; then
    echo ""
    echo "ERROR: Some images are missing. Run prepare-cache.sh to build them."
    exit 1
fi

echo ""
echo "All required images are present."
echo "Total cache size: $(du -sh "$CRS_CACHE_DIR" | cut -f1)"
