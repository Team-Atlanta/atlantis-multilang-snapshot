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

# Load images from /out/images/ (docker load auto-detects gzip)
echo "Loading images from /out/images/..."
docker load -i /out/images/crs-multilang.tar.gz
docker load -i /out/images/joern.tar.gz
docker load -i /out/images/redis.tar.gz

# Set environment variables for docker-compose
export HARNESS_NAME="$HARNESS_NAME"
export TARBALL_DIR="/out/tarballs"
export CPUSET_CPUS="${CPUSET_CPUS:-0-7}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-16G}"
export LITELLM_URL="${LITELLM_URL:-}"
export LITELLM_KEY="${LITELLM_KEY:-}"

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
