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
echo "Building fuzzers via run.py build..."
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir "$TARBALL_DIR" \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification \
    --start-other-services

# Step 6: Create tarballs for CRS runner
echo "Creating tarballs for CRS runner..."
cd /out && tar -cvzf "$TARBALL_DIR/fuzzers.tar.gz" . && cd /crs-multilang

# Create project.tar.gz from the actual project directory (contains project.yaml, .aixcc/, etc.)
PROJECT_DIR="/crs-multilang/libs/oss-fuzz/projects/${PROJECT_NAME}"
if [ -d "$PROJECT_DIR" ]; then
    echo "Creating project.tar.gz from $PROJECT_DIR..."
    cd "$PROJECT_DIR" && tar -cvzf "$TARBALL_DIR/project.tar.gz" . && cd /crs-multilang
else
    echo "WARNING: Project directory not found at $PROJECT_DIR, creating empty project.tar.gz"
    mkdir -p /tmp/empty_project
    touch /tmp/empty_project/.placeholder
    cd /tmp/empty_project && tar -cvzf "$TARBALL_DIR/project.tar.gz" . && cd /crs-multilang
fi

# Pull redis if not present (runner will use it directly from host daemon)
if ! docker image inspect redis:latest > /dev/null 2>&1; then
    echo "Pulling redis:latest..."
    docker pull redis:latest
fi

touch "$TARBALL_DIR/DONE"

echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
echo "Tarballs in $TARBALL_DIR:"
ls -la "$TARBALL_DIR"
