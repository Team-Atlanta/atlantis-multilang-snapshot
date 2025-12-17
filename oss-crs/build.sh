#!/bin/bash
set -eu

echo "=== CRS-Multilang Build Phase (Host Docker) ==="
echo "Using parent image: $PARENT_IMAGE"
echo "Project name: $PROJECT_NAME"

cd /crs-multilang

# Step 1: Verify Docker socket is available
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker socket not available. Ensure /var/run/docker.sock is mounted."
    exit 1
fi
echo "Docker daemon accessible via host socket"

# Step 2: Verify parent image exists on host daemon
# With host docker socket, the image is already on the host - no need to load from tarball
if ! docker image inspect "$PARENT_IMAGE" > /dev/null 2>&1; then
    echo "ERROR: Parent image not found: $PARENT_IMAGE"
    echo "Ensure oss-crs has built the project image before running CRS build."
    exit 1
fi
echo "Parent image found: $PARENT_IMAGE"

# Step 3: Extract source code from parent image
# Use HOST paths for docker volume mounts when HOST_OUT_DIR is set
HOST_OUT="${HOST_OUT_DIR:-/out}"

WORKDIR=$(docker inspect --format='{{.Config.WorkingDir}}' "$PARENT_IMAGE" 2>/dev/null || true)
if [ -z "$WORKDIR" ]; then
    WORKDIR="/src"
fi
echo "Extracting source from $PARENT_IMAGE:$WORKDIR to repo.tar.gz..."
docker run --rm -v "$HOST_OUT:/out" "$PARENT_IMAGE" \
    sh -c "cd '$WORKDIR' && tar -czf /out/repo.tar.gz ."

# Step 4: Build CRS docker images using run.py build_crs
# Docker client packages local context (/crs-multilang) and sends to host daemon
# This works with host docker socket because context is sent as tarball, not path
echo "Building CRS docker images via run.py build_crs..."
python3 run.py build_crs

# Build multilang-runner-joern (not included in build_crs, but needed for runner)
echo "Building multilang-runner-joern..."
docker build -t multilang-runner-joern -f joern/Dockerfile .

# Tag images with namespace for compatibility (run.py expects crs-multilang/crs-multilang:latest)
echo "Tagging images with namespace..."
docker tag crs-multilang crs-multilang/crs-multilang:latest
docker tag multilang-lsp-base crs-multilang/multilang-lsp-base:latest
docker tag multilang-c-archive crs-multilang/multilang-c-archive:latest
docker tag multilang-jvm-archive crs-multilang/multilang-jvm-archive:latest
docker tag multilang-runner-joern crs-multilang/multilang-runner-joern:latest

# Step 5: Build fuzzers using run.py build
# run.py creates repo.tar.gz, fuzzers.tar.gz, project.tar.gz in --out-dir
echo "Building fuzzers via run.py build..."
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir /out \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification \
    --start-other-services

# Pull redis if not present (runner will use it directly from host daemon)
if ! docker image inspect redis:latest > /dev/null 2>&1; then
    echo "Pulling redis:latest..."
    docker pull redis:latest
fi

# Mark build as complete
touch /out/DONE

echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
