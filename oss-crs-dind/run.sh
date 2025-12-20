#!/bin/bash
set -eu

# CRS-Multilang Run Phase (DinD Mode)
#
# This script runs inside the DinD runner container. Key architecture points:
#
# 1. The Docker daemon runs INSIDE this container (DinD = Docker-in-Docker)
# 2. docker-compose.yml uses CONTAINER paths (/artifacts, /out), not HOST paths
# 3. These paths are mounted from the host by oss-crs compose.yaml.j2
# 4. No HOST_* environment variables are needed (unlike host_docker_builder mode)
#
# Volume mount chain:
#   Host: build/artifacts/.../  →  DinD: /artifacts/  →  Nested CRS: /tarballs/, /artifacts/
#   Host: build/out/.../        →  DinD: /out/        →  Nested CRS: /out/

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

# Start Docker daemon (we use ENTRYPOINT so base image's startup is bypassed)
echo ""
echo "Starting Docker daemon..."
/usr/local/bin/start-docker.sh &

# Wait for Docker daemon to be ready
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

# Debug: verify artifacts are accessible
echo ""
echo "Verifying artifacts accessibility..."
echo "Contents of /artifacts/:"
ls -la /artifacts/ || echo "ERROR: /artifacts/ not accessible"
echo ""
echo "Contents of /artifacts/tarballs/:"
ls -la /artifacts/tarballs/ || echo "ERROR: /artifacts/tarballs/ not accessible"
echo ""

# Signal handling for graceful shutdown
# When outer DinD container receives SIGTERM/SIGINT, propagate to nested containers
cleanup() {
    echo ""
    echo "=== Received shutdown signal, stopping gracefully ==="
    cd /crs-runner
    # Give CRS time to save results (30 second timeout)
    docker compose -f "$COMPOSE_FILE" down --timeout 30 || true
    echo "=== Cleanup complete ==="
    exit 0
}
trap cleanup SIGTERM SIGINT

# Start all services with docker-compose
echo ""
echo "Starting services with docker compose..."
cd /crs-runner
docker compose -f "$COMPOSE_FILE" up --abort-on-container-exit &
COMPOSE_PID=$!

# Wait for compose to finish (or be interrupted)
wait $COMPOSE_PID
EXIT_CODE=$?

echo ""
echo "=== Run complete (exit code: $EXIT_CODE) ==="
