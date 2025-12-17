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
export TARBALL_DIR="/out/tarballs"
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

# HOST_OUT_DIR is used for docker volume mounts when using host docker socket
# If not set, defaults to /out (for DinD mode compatibility)
export HOST_OUT_DIR="${HOST_OUT_DIR:-/out}"

# Generate crs.config and set HOST_CRS_CONFIG for docker-compose
HOST_CRS_CONFIG="${HOST_OUT_DIR}/crs.config"
cat > /out/crs.config << EOF
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
cat /out/crs.config

# Start all services with docker compose
echo "Starting services with docker compose..."
cd /app
docker compose up --abort-on-container-exit

echo "=== Run complete ==="
