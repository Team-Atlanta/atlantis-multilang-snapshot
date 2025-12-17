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
TARBALL_DIR=/out/tarballs
mkdir -p "$TARBALL_DIR"

WORKDIR=$(docker inspect --format='{{.Config.WorkingDir}}' "$PARENT_IMAGE" 2>/dev/null || true)
if [ -z "$WORKDIR" ]; then
    WORKDIR="/src"
fi
echo "Extracting source from $PARENT_IMAGE:$WORKDIR to repo.tar.gz..."
docker run --rm -v "$TARBALL_DIR:/tarballs" "$PARENT_IMAGE" \
    sh -c "cd '$WORKDIR' && tar -cvzf /tarballs/repo.tar.gz ."

# Step 4: Build fuzzers using run.py build
echo "Building fuzzers via run.py build..."
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir "$TARBALL_DIR" \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification

# Step 5: Create tarballs for CRS runner
echo "Creating tarballs for CRS runner..."
cd /out && tar -cvzf "$TARBALL_DIR/fuzzers.tar.gz" . && cd /crs-multilang

mkdir -p /tmp/empty_project
touch /tmp/empty_project/.placeholder
cd /tmp/empty_project && tar -cvzf "$TARBALL_DIR/project.tar.gz" . && cd /crs-multilang

# Step 6: Save runtime images for DinD runner
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
