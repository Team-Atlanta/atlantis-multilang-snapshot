#!/bin/bash
# Verify that all required cached images exist
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Verifying cache at $CRS_CACHE_DIR..."

missing=0
for img in "${REQUIRED_IMAGES[@]}"; do
    base_name="${img%.tar.gz}"
    base_name="${base_name%.tar}"

    # Check for either .tar or .tar.gz
    if [ -f "$CRS_CACHE_DIR/${base_name}.tar" ]; then
        img_path="$CRS_CACHE_DIR/${base_name}.tar"
        size=$(du -h "$img_path" | cut -f1)
        echo "  OK: ${base_name}.tar ($size)"
    elif [ -f "$CRS_CACHE_DIR/${base_name}.tar.gz" ]; then
        img_path="$CRS_CACHE_DIR/${base_name}.tar.gz"
        size=$(du -h "$img_path" | cut -f1)
        echo "  OK: ${base_name}.tar.gz ($size)"
    else
        echo "ERROR: Missing $base_name (.tar or .tar.gz)"
        missing=1
    fi
done

if [ $missing -eq 1 ]; then
    echo ""
    echo "Cache is incomplete. Run prepare-cache.sh first to create the cache:"
    echo "  cd $(dirname "$SCRIPT_DIR") && ./oss-crs/prepare-cache.sh"
    exit 1
fi

echo "Cache verified OK"
