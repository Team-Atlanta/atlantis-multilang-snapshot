#!/bin/bash
set -eu

# Source config for image arrays
source /crs-runner/config.sh

HARNESS_NAME="$1"
shift || true

echo "=== CRS-Multilang Run Phase (DinD) ==="
echo "Harness: $HARNESS_NAME"
echo "Environment:"
echo "  CPUSET_CPUS: ${CPUSET_CPUS:-0-7}"
echo "  MEMORY_LIMIT: ${MEMORY_LIMIT:-16G}"
echo "  CRS_INPUT_GENS: ${CRS_INPUT_GENS:-given_fuzzer}"
echo ""
echo "Docker data-root: /artifacts/docker-data (persisted from build phase)"

# Docker daemon is auto-started by cruizba/ubuntu-dind entrypoint
# With data-root=/artifacts/docker-data, Docker sees images from build phase
echo ""
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
    sleep 1
done
echo "Docker daemon ready"

# Verify runtime images are available (should be persisted from build phase)
echo ""
echo "Checking runtime images..."

IMAGES_AVAILABLE=true
for img in "${DOCKER_IMAGES_RUNTIME[@]}"; do
    if ! docker image inspect "$img" > /dev/null 2>&1; then
        IMAGES_AVAILABLE=false
        break
    fi
done

if [ "$IMAGES_AVAILABLE" = true ]; then
    echo "  Images available from build phase (persisted in /artifacts/docker-data/)"
    for img in "${DOCKER_IMAGES_RUNTIME[@]}"; do
        echo "  ✓ $img"
    done
else
    echo "  WARNING: Images not found in Docker data. Attempting to load from cache..."
    # Fallback: try to load from shared cache if available
    if [ -d "/cache/images" ]; then
        echo "  Loading from /cache/images/..."
        for img in "${DOCKER_IMAGES_RUNTIME[@]}"; do
            filename="${img%%:*}.tar.gz"
            tarball="/cache/images/$filename"
            if [ -f "$tarball" ]; then
                echo "  Loading $img..."
                pigz -dc "$tarball" | docker load
            else
                echo "  ✗ $tarball not found"
            fi
        done
    else
        echo "  ERROR: No cache available at /cache/images/"
        echo "  Ensure build phase completed successfully."
        exit 1
    fi
fi

# Check LSP runner image for MLLA mode
LSP_IMAGE_NAME=$(get_lsp_image_name "${CRS_TARGET:-mock-c}")
if docker image inspect "$LSP_IMAGE_NAME" > /dev/null 2>&1; then
    echo "  ✓ $LSP_IMAGE_NAME (LSP runner for MLLA)"
    LSP_AVAILABLE=true
else
    echo "  Note: $LSP_IMAGE_NAME not available (MLLA mode will not work)"
    LSP_AVAILABLE=false
fi

# Final verification of all runtime images
echo ""
echo "Verifying runtime images..."
MISSING=false
for img in "${DOCKER_IMAGES_RUNTIME[@]}"; do
    if docker image inspect "$img" > /dev/null 2>&1; then
        echo "  ✓ $img"
    else
        echo "  ✗ $img (MISSING)"
        MISSING=true
    fi
done

if [ "$MISSING" = true ]; then
    echo ""
    echo "ERROR: Some runtime images are missing."
    echo "Ensure build phase completed successfully."
    exit 1
fi

# Determine compose file based on CRS_INPUT_GENS
CRS_INPUT_GENS="${CRS_INPUT_GENS:-given_fuzzer}"
if echo "$CRS_INPUT_GENS" | grep -qE "(mlla|testlang_input_gen)"; then
    # MLLA mode requires CRS_TARGET and LSP runner image
    if [ -z "${CRS_TARGET:-}" ]; then
        echo "ERROR: CRS_TARGET must be set for MLLA mode"
        exit 1
    fi
    if [ "$LSP_AVAILABLE" != true ]; then
        echo "ERROR: LSP runner image not available for MLLA mode."
        echo "Ensure build phase created the LSP runner image."
        exit 1
    fi
    COMPOSE_FILE="/crs-runner/docker-compose.mlla.yml"
    echo "Using MLLA mode (docker-compose.mlla.yml)"
else
    COMPOSE_FILE="/crs-runner/docker-compose.yml"
    echo "Using fuzzing-only mode (docker-compose.yml)"
fi

# Generate crs.config
echo ""
echo "Generating crs.config..."
IFS=',' read -ra INPUT_GENS_ARRAY <<< "$CRS_INPUT_GENS"
INPUT_GENS_JSON=$(printf '"%s",' "${INPUT_GENS_ARRAY[@]}" | sed 's/,$//')

cat > /tmp/crs.config << EOF
{
    "target_harnesses": ["${HARNESS_NAME}"],
    "modules": ["uniafl"],
    "others": {
        "input_gens": [${INPUT_GENS_JSON}]
    }
}
EOF

echo "Generated /tmp/crs.config:"
cat /tmp/crs.config

# Set environment variables for docker-compose
export HARNESS_NAME="$HARNESS_NAME"
export CPUSET_CPUS="${CPUSET_CPUS:-0-7}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-16G}"
export LITELLM_URL="${LITELLM_URL:-}"
export LITELLM_KEY="${LITELLM_KEY:-}"
# Sanitize CRS_TARGET for Docker image naming (replace / with _)
CRS_TARGET_RAW="${CRS_TARGET:-}"
export CRS_TARGET=$(echo "$CRS_TARGET_RAW" | tr '/' '_')
export CRS_NAME="${CRS_NAME:-crs-multilang}"
export CRS_SKIP_SAVE="${CRS_SKIP_SAVE:-}"
export CRS_INPUT_GENS="$CRS_INPUT_GENS"

# Start all services with docker-compose
# No cleanup sidecar needed - when this container stops, nested Docker daemon dies
echo ""
echo "Starting services with docker compose..."
cd /crs-runner
docker compose -f "$COMPOSE_FILE" up --abort-on-container-exit

echo ""
echo "=== Run complete ==="
