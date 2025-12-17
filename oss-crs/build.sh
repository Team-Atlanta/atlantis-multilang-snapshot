#!/bin/bash
set -eu

echo "=== CRS-Multilang Build Phase ==="
echo "Project name: $PROJECT_NAME"

cd /crs-multilang

# Step 1: Verify Docker socket is available (needed for build_crs)
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker socket not available. Ensure /var/run/docker.sock is mounted."
    exit 1
fi
echo "Docker daemon accessible via host socket"

# Step 2: Create repo.tar.gz from source (source is at /src from parent_image)
echo "Creating repo.tar.gz from /src..."
tar -czf /out/repo.tar.gz -C /src .

# Step 3: Build CRS docker images using run.py build_crs
echo "Building CRS docker images via run.py build_crs..."
python3 run.py build_crs

# Build multilang-runner-joern (not included in build_crs, but needed for runner)
echo "Building multilang-runner-joern..."
docker build -t multilang-runner-joern -f joern/Dockerfile .

# Tag images with namespace for compatibility
echo "Tagging images with namespace..."
docker tag crs-multilang crs-multilang/crs-multilang:latest
docker tag multilang-lsp-base crs-multilang/multilang-lsp-base:latest
docker tag multilang-c-archive crs-multilang/multilang-c-archive:latest
docker tag multilang-jvm-archive crs-multilang/multilang-jvm-archive:latest
docker tag multilang-runner-joern crs-multilang/multilang-runner-joern:latest

# Step 4: Build fuzzers using run.py build
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
