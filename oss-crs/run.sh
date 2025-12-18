#!/bin/bash
set -eu

HARNESS_NAME="$1"
shift || true

echo "=== CRS-Multilang Run Phase (Host Docker) ==="
echo "Harness: $HARNESS_NAME"
echo "Environment:"
echo "  CPUSET_CPUS: ${CPUSET_CPUS:-not set}"
echo "  MEMORY_LIMIT: ${MEMORY_LIMIT:-not set}"
echo "  RUN_FUZZER_MODE: ${RUN_FUZZER_MODE:-not set}"

# Verify Docker socket is available (using host docker daemon)
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker socket not available. Ensure /var/run/docker.sock is mounted."
    exit 1
fi
echo "Docker daemon accessible via host socket"

# Verify required images exist on host daemon (built by builder phase)
echo "Verifying images on host docker daemon..."
for img in crs-multilang/crs-multilang:latest crs-multilang/multilang-runner-joern:latest redis:latest; do
    if ! docker image inspect "$img" > /dev/null 2>&1; then
        echo "ERROR: Image not found: $img"
        echo "Ensure builder phase completed successfully."
        exit 1
    fi
    echo "  Found: $img"
done

# Set environment variables for docker-compose
export HARNESS_NAME="$HARNESS_NAME"
export CPUSET_CPUS="${CPUSET_CPUS:-0-7}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-16G}"
export LITELLM_URL="${LITELLM_URL:-}"
# Read LiteLLM key from /keys/api_key (oss-crs convention) or fall back to env var
if [ -f /keys/api_key ]; then
    export LITELLM_KEY="$(cat /keys/api_key)"
else
    export LITELLM_KEY="${LITELLM_KEY:-}"
fi
export CRS_TARGET="${CRS_TARGET:-}"
export CRS_NAME="${CRS_NAME:-crs-multilang}"
export CRS_SKIP_SAVE="${CRS_SKIP_SAVE:-}"

# HOST_OUT_DIR is used for docker volume mounts when using host docker socket
# If not set, defaults to /out (for DinD mode compatibility)
export HOST_OUT_DIR="${HOST_OUT_DIR:-/out}"

# HOST_ARTIFACT_DIR contains tarballs (created by builder phase)
# If not set, defaults to HOST_OUT_DIR for backward compatibility
export HOST_ARTIFACT_DIR="${HOST_ARTIFACT_DIR:-$HOST_OUT_DIR}"

# Network configuration:
# - crs-internal: Always created, project-scoped, isolated per project/harness
# - crs-external: For LiteLLM connectivity
#   - If CRS_EXTERNAL_NETWORK is set: join the existing external network (for oss-crs)
#   - If not set: create a local network (for standalone testing)
if [ -n "${CRS_EXTERNAL_NETWORK:-}" ]; then
    echo "Using external network for LiteLLM: $CRS_EXTERNAL_NETWORK"
    export CRS_NETWORK_EXTERNAL="true"
    # CRS_EXTERNAL_NETWORK is already set by the caller
else
    echo "Using local networks (standalone mode)"
    export CRS_NETWORK_EXTERNAL="false"
    # Create a unique local network name per project/harness to avoid conflicts
    # This will be overwritten after SAFE_TARGET/SAFE_HARNESS are computed below
fi

# Sanitize names for docker compose project/container naming (replace special chars with underscore)
sanitize_name() {
    echo "$1" | tr -c 'a-zA-Z0-9_-' '_' | sed 's/_*$//'
}
SAFE_TARGET=$(sanitize_name "${CRS_TARGET:-crs}")
SAFE_HARNESS=$(sanitize_name "$HARNESS_NAME")

# Export sanitized names for docker-compose container naming only
# Keep original CRS_TARGET and HARNESS_NAME for CRS internal use
export SAFE_TARGET
export SAFE_HARNESS

# Set unique external network name for standalone mode (after SAFE_TARGET/SAFE_HARNESS are computed)
if [ "${CRS_NETWORK_EXTERNAL}" = "false" ]; then
    # Use unique network name per project/harness to avoid conflicts
    export CRS_EXTERNAL_NETWORK="${SAFE_TARGET}_${SAFE_HARNESS}_external"
    echo "External network (local): $CRS_EXTERNAL_NETWORK"
fi

# Generate harness-specific crs.config to avoid conflicts with concurrent runs
HOST_CRS_CONFIG="${HOST_OUT_DIR}/crs.config.${SAFE_HARNESS}"
cat > "/out/crs.config.${SAFE_HARNESS}" << EOF
{
    "target_harnesses": ["${HARNESS_NAME}"],
    "modules": ["uniafl"],
    "others": {
        "input_gens": ["given_fuzzer"]
    }
}
EOF

export HOST_CRS_CONFIG
echo "Generated crs.config at $HOST_CRS_CONFIG:"
cat "/out/crs.config.${SAFE_HARNESS}"

# Start all services with docker compose
# Use unique project name to avoid conflicts when running multiple instances
COMPOSE_PROJECT="${SAFE_TARGET}_${SAFE_HARNESS}"
export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"

echo "Starting services with docker compose (project: $COMPOSE_PROJECT)..."
cd /app

# Run and capture exit code
set +e
docker compose up --abort-on-container-exit --exit-code-from crs
EXIT_CODE=$?
set -e

# Cleanup containers
echo "Cleaning up containers..."
docker compose down --remove-orphans 2>/dev/null || true

echo "=== Run complete (exit code: $EXIT_CODE) ==="
exit $EXIT_CODE
