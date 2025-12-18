#!/bin/bash
set -eu

HARNESS_NAME="$1"
shift || true

echo "=== CRS-Multilang Run Phase (DinD) ==="
echo "Harness: $HARNESS_NAME"
echo "Environment:"
echo "  CPUSET_CPUS: ${CPUSET_CPUS:-0-7}"
echo "  MEMORY_LIMIT: ${MEMORY_LIMIT:-16G}"
echo "  CRS_INPUT_GENS: ${CRS_INPUT_GENS:-given_fuzzer}"

# Start Docker daemon (provided by cruizba/ubuntu-dind)
echo ""
echo "Starting Docker daemon..."
start-docker.sh

# Wait for Docker to be ready
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
    sleep 1
done
echo "Docker daemon ready"

# Load images from /out/images/ (docker load auto-detects gzip)
echo ""
echo "Loading images from /out/images/..."
docker load -i /out/images/crs-multilang.tar.gz
docker load -i /out/images/joern.tar.gz
docker load -i /out/images/redis.tar.gz

# Determine compose file based on CRS_INPUT_GENS
CRS_INPUT_GENS="${CRS_INPUT_GENS:-given_fuzzer}"
if echo "$CRS_INPUT_GENS" | grep -qE "(mlla|testlang_input_gen)"; then
    COMPOSE_FILE="/app/docker-compose.mlla.yml"
    echo "Using MLLA mode (docker-compose.mlla.yml)"
else
    COMPOSE_FILE="/app/docker-compose.yml"
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
export CRS_TARGET="${CRS_TARGET:-}"
export CRS_NAME="${CRS_NAME:-crs-multilang}"
export CRS_SKIP_SAVE="${CRS_SKIP_SAVE:-}"
export CRS_INPUT_GENS="$CRS_INPUT_GENS"

# Start all services with docker-compose
# No cleanup sidecar needed - when this container stops, nested Docker daemon dies
echo ""
echo "Starting services with docker-compose..."
cd /app
docker-compose -f "$COMPOSE_FILE" up --abort-on-container-exit

echo ""
echo "=== Run complete ==="
