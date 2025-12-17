#!/bin/bash
# Load cached Docker images from tar files (parallel)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Max parallel loads (adjust based on disk I/O and memory)
MAX_PARALLEL=${MAX_PARALLEL:-4}

echo "Loading cached images from $CRS_CACHE_DIR (max $MAX_PARALLEL parallel)..."

# Verify all images exist first
for img in "${REQUIRED_IMAGES[@]}"; do
    img_path="$CRS_CACHE_DIR/$img"
    if [ ! -f "$img_path" ]; then
        echo "ERROR: Image file not found: $img_path"
        echo "Run verify-cache.sh first to check cache status."
        exit 1
    fi
done

# Load images in parallel with controlled concurrency
# Prefer .tar over .tar.gz for faster loading
load_image() {
    local img="$1"
    local base_name="${img%.tar.gz}"
    base_name="${base_name%.tar}"

    # Check for .tar first (faster), then .tar.gz
    local img_path=""
    if [ -f "$CRS_CACHE_DIR/${base_name}.tar" ]; then
        img_path="$CRS_CACHE_DIR/${base_name}.tar"
    elif [ -f "$CRS_CACHE_DIR/${base_name}.tar.gz" ]; then
        img_path="$CRS_CACHE_DIR/${base_name}.tar.gz"
    else
        echo "[ERROR] No cache file found for $base_name (.tar or .tar.gz)"
        return 1
    fi

    echo "[START] Loading $(basename "$img_path")..."
    if docker load -i "$img_path" > /dev/null 2>&1; then
        echo "[DONE]  Loaded $(basename "$img_path")"
    else
        echo "[ERROR] Failed to load $(basename "$img_path")"
        return 1
    fi
}
export -f load_image
export CRS_CACHE_DIR

# Use parallel if available, otherwise fall back to xargs
if command -v parallel &> /dev/null; then
    printf '%s\n' "${REQUIRED_IMAGES[@]}" | parallel -j "$MAX_PARALLEL" load_image {}
else
    # Fallback: use background jobs with semaphore pattern
    running=0
    pids=()

    for img in "${REQUIRED_IMAGES[@]}"; do
        load_image "$img" &
        pids+=($!)
        running=$((running + 1))

        # Wait if we hit max parallel
        if [ "$running" -ge "$MAX_PARALLEL" ]; then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
            running=$((running - 1))
        fi
    done

    # Wait for remaining jobs
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
fi

echo ""
echo "All images loaded successfully:"
docker images | grep -E "multilang-|crs-multilang|redis" | head -15 || true
