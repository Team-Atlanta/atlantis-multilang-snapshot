#!/bin/bash
# Load cached Docker images from tar files (parallel)
# Supports language-specific image loading via FUZZING_LANGUAGE env var
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Max parallel loads (adjust based on disk I/O and memory)
MAX_PARALLEL=${MAX_PARALLEL:-4}

# Which image set to load (default: all required images)
IMAGE_SET="${1:-all}"

# Get language-specific images based on FUZZING_LANGUAGE env var
get_language_images() {
    # Check if language-specific arrays are defined (backward compatibility)
    if [ -z "${BASE_BUILDER_IMAGES_C+x}" ]; then
        # Arrays not defined, fall back to REQUIRED_IMAGES
        echo "${REQUIRED_IMAGES[@]}"
        return
    fi

    case "$FUZZING_LANGUAGE" in
        c|c++|cpp)
            # C/C++ projects: skip builder-jvm and jvm-archive
            echo "${BASE_BUILDER_IMAGES_C[@]} ${ARCHIVE_IMAGES_C[@]} ${CRS_IMAGES[@]}"
            ;;
        jvm)
            # JVM projects: skip c-archive
            echo "${BASE_BUILDER_IMAGES_JVM[@]} ${ARCHIVE_IMAGES_JVM[@]} ${CRS_IMAGES[@]}"
            ;;
        *)
            # Empty or unknown: load all images
            echo "${REQUIRED_IMAGES[@]}"
            ;;
    esac
}

case "$IMAGE_SET" in
    all)
        # Use language-specific images if FUZZING_LANGUAGE is set
        if [ -n "$FUZZING_LANGUAGE" ]; then
            read -ra IMAGES_TO_LOAD <<< "$(get_language_images)"
        else
            IMAGES_TO_LOAD=("${REQUIRED_IMAGES[@]}")
        fi
        ;;
    runtime)
        IMAGES_TO_LOAD=("${RUNTIME_IMAGES[@]}")
        ;;
    *)
        echo "Usage: $0 [all|runtime]"
        echo "  all     - Load all images (for builder, respects FUZZING_LANGUAGE)"
        echo "  runtime - Load only runtime images (for runner)"
        echo ""
        echo "Environment variables:"
        echo "  FUZZING_LANGUAGE - Set to 'c', 'c++', 'cpp', or 'jvm' to load only required images"
        echo "                     Default: empty (load all images)"
        echo ""
        echo "Examples:"
        echo "  FUZZING_LANGUAGE=c ./load-cache.sh all    # Load C-only images (skip jvm-archive, builder-jvm)"
        echo "  FUZZING_LANGUAGE=jvm ./load-cache.sh all  # Load JVM-only images (skip c-archive)"
        exit 1
        ;;
esac

echo "Loading cached images from $CRS_CACHE_DIR (max $MAX_PARALLEL parallel)..."
if [ -n "$FUZZING_LANGUAGE" ]; then
    echo "Language: $FUZZING_LANGUAGE (loading language-specific images only)"
else
    echo "Language: not set (loading all images)"
fi
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

# Check if we have tarballs or need to pull from registry
USE_REGISTRY=false
MISSING_TARBALLS=()
for img in "${IMAGES_TO_LOAD[@]}"; do
    img_path=$(find_image_file "$img")
    if [ -z "$img_path" ]; then
        MISSING_TARBALLS+=("$img")
    fi
done

if [ ${#MISSING_TARBALLS[@]} -gt 0 ]; then
    if [ -n "$CRS_REGISTRY" ]; then
        echo "Some tarballs missing, will pull from registry: $CRS_REGISTRY"
        USE_REGISTRY=true
    else
        echo "ERROR: Missing tarballs and CRS_REGISTRY not set:"
        for img in "${MISSING_TARBALLS[@]}"; do
            echo "  - $img"
        done
        echo ""
        echo "Options:"
        echo "  1. Run prepare-cache.sh to create tarballs"
        echo "  2. Set CRS_REGISTRY to pull from container registry"
        echo "     export CRS_REGISTRY=\"ghcr.io/team-atlanta/crs-multilang\""
        exit 1
    fi
fi

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

    if [ -n "$img_path" ]; then
        # Load from tarball
        echo "[START] Loading $img_base from tarball..."
        if docker load -i "$img_path" > /dev/null 2>&1; then
            echo "[DONE]  Loaded $img_base"
        else
            echo "[ERROR] Failed to load $img_base"
            return 1
        fi
    elif [ -n "$CRS_REGISTRY" ]; then
        # Pull from registry
        local registry_img="$CRS_REGISTRY/${img_base}:latest"
        local local_img="crs-multilang/${img_base}:latest"
        echo "[START] Pulling $img_base from registry..."
        if docker pull "$registry_img" > /dev/null 2>&1; then
            # Tag as local image name for compatibility
            docker tag "$registry_img" "$local_img" 2>/dev/null || true
            echo "[DONE]  Pulled $img_base"
        else
            echo "[ERROR] Failed to pull $img_base from $registry_img"
            return 1
        fi
    else
        echo "[ERROR] No tarball and no registry for $img_base"
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
# Use DOCKER_IMAGES_ALL from config.sh
for img in "${DOCKER_IMAGES_ALL[@]}"; do
    if docker image inspect "$img" > /dev/null 2>&1; then
        echo "  ✓ $img"
    fi
done
