#!/bin/bash
# Load cached Docker images from tar files (parallel)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Max parallel loads (adjust based on disk I/O and memory)
MAX_PARALLEL=${MAX_PARALLEL:-4}

# Which image set to load (default: all required images)
IMAGE_SET="${1:-all}"

case "$IMAGE_SET" in
    all)
        IMAGES_TO_LOAD=("${REQUIRED_IMAGES[@]}")
        ;;
    runtime)
        IMAGES_TO_LOAD=("${RUNTIME_IMAGES[@]}")
        ;;
    *)
        echo "Usage: $0 [all|runtime]"
        echo "  all     - Load all images (for builder)"
        echo "  runtime - Load only runtime images (for runner)"
        exit 1
        ;;
esac

echo "Loading cached images from $CRS_CACHE_DIR (max $MAX_PARALLEL parallel)..."
echo "Image set: $IMAGE_SET (${#IMAGES_TO_LOAD[@]} images)"
echo ""

# Find image file (support both .tar and .tar.gz)
find_image_file() {
    local img="$1"
    local img_base="${img%.tar.gz}"
    img_base="${img_base%.tar}"

    if [ -f "$CRS_CACHE_DIR/${img_base}.tar" ]; then
        echo "$CRS_CACHE_DIR/${img_base}.tar"
    elif [ -f "$CRS_CACHE_DIR/${img_base}.tar.gz" ]; then
        echo "$CRS_CACHE_DIR/${img_base}.tar.gz"
    else
        echo ""
    fi
}

# Verify all images exist first
for img in "${IMAGES_TO_LOAD[@]}"; do
    img_path=$(find_image_file "$img")
    if [ -z "$img_path" ]; then
        echo "ERROR: Image file not found: $img"
        echo "Run verify-cache.sh first to check cache status."
        exit 1
    fi
done

# Load images in parallel with controlled concurrency
load_image() {
    local img="$1"
    local img_base="${img%.tar.gz}"
    img_base="${img_base%.tar}"

    # Find the actual file
    local img_path=""
    if [ -f "$CRS_CACHE_DIR/${img_base}.tar" ]; then
        img_path="$CRS_CACHE_DIR/${img_base}.tar"
    elif [ -f "$CRS_CACHE_DIR/${img_base}.tar.gz" ]; then
        img_path="$CRS_CACHE_DIR/${img_base}.tar.gz"
    fi

    echo "[START] Loading $img_base..."
    if docker load -i "$img_path" > /dev/null 2>&1; then
        echo "[DONE]  Loaded $img_base"
    else
        echo "[ERROR] Failed to load $img_base"
        return 1
    fi
}

# Use background jobs with semaphore pattern for parallel loading
running=0
pids=()
failed=0

for img in "${IMAGES_TO_LOAD[@]}"; do
    load_image "$img" &
    pids+=($!)
    running=$((running + 1))

    # Wait if we hit max parallel
    if [ "$running" -ge "$MAX_PARALLEL" ]; then
        wait "${pids[0]}" || failed=$((failed + 1))
        pids=("${pids[@]:1}")
        running=$((running - 1))
    fi
done

# Wait for remaining jobs
for pid in "${pids[@]}"; do
    wait "$pid" || failed=$((failed + 1))
done

echo ""
if [ "$failed" -gt 0 ]; then
    echo "ERROR: $failed image(s) failed to load"
    exit 1
fi

echo "All images loaded successfully:"
docker images | grep -E "multilang-|crs-multilang|redis" | head -15 || true
