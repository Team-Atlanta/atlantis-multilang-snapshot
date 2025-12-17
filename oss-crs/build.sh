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

# Step 2: Load the project image from tarball (provided by oss-crs)
echo "Loading project image from /project-image.tar..."
docker load -i /project-image.tar

# Step 3: Prepare tarballs for run.py build
# Use HOST paths for docker volume mounts when HOST_OUT_DIR is set
TARBALL_DIR=/out/tarballs
HOST_TARBALL_DIR="${HOST_OUT_DIR:-/out}/tarballs"
mkdir -p "$TARBALL_DIR"

WORKDIR=$(docker inspect --format='{{.Config.WorkingDir}}' "$PARENT_IMAGE" 2>/dev/null || true)
if [ -z "$WORKDIR" ]; then
    WORKDIR="/src"
fi
echo "Extracting source from $PARENT_IMAGE:$WORKDIR to repo.tar.gz..."
docker run --rm -v "$HOST_TARBALL_DIR:/tarballs" "$PARENT_IMAGE" \
    sh -c "cd '$WORKDIR' && tar -cvzf /tarballs/repo.tar.gz ."

# Step 4: Build CRS docker images on HOST (using HOST_CRS_DIR as build context)
# These are needed for init_codeindexer and other build steps
if [ -n "${HOST_CRS_DIR:-}" ]; then
    echo "Building CRS docker images using host context: $HOST_CRS_DIR"
    docker build -t crs-multilang -f "$HOST_CRS_DIR/Dockerfile" "$HOST_CRS_DIR"
    docker build -t multilang-runner-joern -f "$HOST_CRS_DIR/joern/Dockerfile" "$HOST_CRS_DIR"
    docker build -t multilang-lsp-base -f "$HOST_CRS_DIR/lsp/Dockerfile" "$HOST_CRS_DIR"

    # Tag images with namespace for compatibility
    docker tag crs-multilang crs-multilang/crs-multilang:latest
    docker tag multilang-runner-joern crs-multilang/multilang-runner-joern:latest
else
    echo "WARNING: HOST_CRS_DIR not set, skipping CRS image builds"
fi

# Step 5: Build fuzzers using run.py build
echo "Building fuzzers via run.py build..."
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir "$TARBALL_DIR" \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification

# Step 6: Create tarballs for CRS runner
echo "Creating tarballs for CRS runner..."
cd /out && tar -cvzf "$TARBALL_DIR/fuzzers.tar.gz" . && cd /crs-multilang

mkdir -p /tmp/empty_project
touch /tmp/empty_project/.placeholder
cd /tmp/empty_project && tar -cvzf "$TARBALL_DIR/project.tar.gz" . && cd /crs-multilang

# Step 7: Save runtime images for DinD runner
echo "Saving runtime images to /out/images/..."
IMAGES_DIR=/out/images
mkdir -p "$IMAGES_DIR"

# Save images needed by runner's docker-compose
docker save crs-multilang/crs-multilang:latest -o "$IMAGES_DIR/crs-multilang.tar"
docker save crs-multilang/multilang-runner-joern:latest -o "$IMAGES_DIR/multilang-runner-joern.tar"

# Save redis (pull if not present)
if ! docker image inspect redis:latest > /dev/null 2>&1; then
    docker pull redis:latest
fi
docker save redis:latest -o "$IMAGES_DIR/redis.tar"

touch "$TARBALL_DIR/DONE"

echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
echo "Images in /out/images/:"
ls -la /out/images/
