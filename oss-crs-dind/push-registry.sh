#!/bin/bash
# Push CRS Docker images to a container registry (e.g., ghcr.io)
#
# Prerequisites:
#   1. Images must be built locally (run prepare-cache.sh --only-build first)
#   2. Login to registry: echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
#
# Usage:
#   ./push-registry.sh ghcr.io/team-atlanta/crs-multilang
#   ./push-registry.sh --dry-run ghcr.io/team-atlanta/crs-multilang
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

# Default registry (same as config.sh)
DEFAULT_REGISTRY="ghcr.io/team-atlanta/atlantis-multilang-snapshot"
REGISTRY="${1:-$DEFAULT_REGISTRY}"

if [ "$REGISTRY" = "--help" ] || [ "$REGISTRY" = "-h" ]; then
    echo "Usage: $0 [--dry-run] [REGISTRY_URL]"
    echo ""
    echo "Default registry: $DEFAULT_REGISTRY"
    echo ""
    echo "Examples:"
    echo "  $0                    # Push to default registry"
    echo "  $0 --dry-run          # Dry run with default registry"
    echo "  $0 ghcr.io/other/repo # Push to custom registry"
    echo ""
    echo "Prerequisites:"
    echo "  1. Build images first: ./prepare-cache.sh --only-build"
    echo "  2. Login to registry:"
    echo "     echo \$GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
    exit 0
fi

# Remove trailing slash if present
REGISTRY="${REGISTRY%/}"

echo "=== Push CRS Images to Registry ==="
echo "Registry: $REGISTRY"
echo "Dry run: $DRY_RUN"
echo ""

# Images to push (excluding redis which should be pulled from official)
IMAGES_TO_PUSH=(
    "multilang-clang:latest"
    "multilang-builder:latest"
    "multilang-builder-jvm:latest"
    "multilang-c-archive:latest"
    "multilang-jvm-archive:latest"
    "crs-multilang:latest"
    "multilang-lsp-base:latest"
    "multilang-runner-joern:latest"
)

# Check all images exist locally
echo "Checking local images..."
MISSING=()
for img in "${IMAGES_TO_PUSH[@]}"; do
    # Check both with and without crs-multilang/ prefix
    if docker image inspect "crs-multilang/$img" > /dev/null 2>&1; then
        echo "  ✓ crs-multilang/$img"
    elif docker image inspect "$img" > /dev/null 2>&1; then
        echo "  ✓ $img"
    else
        echo "  ✗ $img (not found)"
        MISSING+=("$img")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "ERROR: Missing images. Run prepare-cache.sh --only-build first."
    exit 1
fi

echo ""
echo "Tagging and pushing images..."

for img in "${IMAGES_TO_PUSH[@]}"; do
    # Determine source image name
    if docker image inspect "crs-multilang/$img" > /dev/null 2>&1; then
        SRC="crs-multilang/$img"
    else
        SRC="$img"
    fi

    # Target name in registry
    TARGET="$REGISTRY/$img"

    echo ""
    echo "[$img]"
    echo "  Source: $SRC"
    echo "  Target: $TARGET"

    if [ "$DRY_RUN" = true ]; then
        echo "  (dry-run) Would tag and push"
    else
        echo "  Tagging..."
        docker tag "$SRC" "$TARGET"
        echo "  Pushing..."
        docker push "$TARGET"
        echo "  ✓ Done"
    fi
done

echo ""
echo "=== Push Complete ==="
echo ""
echo "Images are now available at:"
for img in "${IMAGES_TO_PUSH[@]}"; do
    echo "  $REGISTRY/$img"
done
echo ""
echo "To use these images, set in config.sh or environment:"
echo "  export CRS_REGISTRY=\"$REGISTRY\""
