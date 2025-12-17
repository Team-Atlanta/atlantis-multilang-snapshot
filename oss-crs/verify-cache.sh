#!/bin/bash
# Verify that all required cached images exist
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Verifying cache at $CRS_CACHE_DIR..."

missing=0
for img in "${REQUIRED_IMAGES[@]}"; do
    if [ ! -f "$CRS_CACHE_DIR/$img" ]; then
        echo "ERROR: Missing $img"
        missing=1
    else
        size=$(du -h "$CRS_CACHE_DIR/$img" | cut -f1)
        echo "  OK: $img ($size)"
    fi
done

if [ $missing -eq 1 ]; then
    echo ""
    echo "Cache is incomplete. Run prepare-cache.sh first to create the cache:"
    echo "  cd $(dirname "$SCRIPT_DIR") && ./oss-crs/prepare-cache.sh"
    exit 1
fi

echo "Cache verified OK"
