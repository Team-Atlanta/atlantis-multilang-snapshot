#!/bin/bash
set -eu

HARNESS_NAME="$1"
shift || true

echo "=== CRS-Multilang Run Phase ==="
echo "Harness: $HARNESS_NAME"
echo "Environment:"
echo "  CPUSET_CPUS: ${CPUSET_CPUS:-not set}"
echo "  MEMORY_LIMIT: ${MEMORY_LIMIT:-not set}"
echo "  RUN_FUZZER_MODE: ${RUN_FUZZER_MODE:-not set}"

# Start Docker daemon (provided by cruizba/ubuntu-dind)
start-docker.sh

# Wait for Docker to be ready
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
    sleep 1
done
echo "Docker daemon ready"

# Load images from /out/images/ (prefer .tar over .tar.gz for speed)
load_runner_image() {
    local base_name="$1"
    if [ -f "/out/images/${base_name}.tar" ]; then
        docker load -i "/out/images/${base_name}.tar"
    elif [ -f "/out/images/${base_name}.tar.gz" ]; then
        docker load -i "/out/images/${base_name}.tar.gz"
    else
        echo "ERROR: Image not found: $base_name (.tar or .tar.gz)"
        exit 1
    fi
}

echo "Loading images from /out/images/..."
load_runner_image "crs-multilang"
load_runner_image "joern"
load_runner_image "redis"

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

# Generate crs.config for given_fuzzer mode
cat > /tmp/crs.config << EOF
{
    "target_harnesses": ["${HARNESS_NAME}"],
    "modules": ["uniafl"],
    "others": {
        "input_gens": ["given_fuzzer"]
    }
}
EOF

echo "Generated /tmp/crs.config:"
cat /tmp/crs.config

# Start all services with docker-compose
echo "Starting services with docker-compose..."
cd /app
docker-compose up --abort-on-container-exit

echo "=== Run complete ==="
