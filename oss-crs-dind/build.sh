#!/bin/bash
set -eu

echo "=== CRS-Multilang Build Phase (DinD) ==="
echo "Using parent image: $PARENT_IMAGE"
echo "Project name: $PROJECT_NAME"

# Start Docker daemon (provided by cruizba/ubuntu-dind)
echo "Starting Docker daemon..."
start-docker.sh

# Wait for Docker to be ready
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
    sleep 1
done
echo "Docker daemon ready"

cd /crs-multilang

# Step 1: Load pre-built CRS docker images from cache (instead of rebuilding)
echo ""
echo "[1/6] Loading cached CRS images..."
source /crs-multilang/oss-crs-dind/config.sh
/crs-multilang/oss-crs-dind/verify-cache.sh
/crs-multilang/oss-crs-dind/load-cache.sh all

# Step 2: Load the project image from tarball (provided by oss-crs)
echo ""
echo "[2/6] Loading project image from /project-image.tar..."
docker load -i /project-image.tar

# Step 3: Prepare tarballs for run.py build
echo ""
echo "[3/6] Preparing tarballs..."
TARBALL_DIR=/out/tarballs
mkdir -p "$TARBALL_DIR"

# Extract source code from parent image's WORKDIR
WORKDIR=$(docker inspect --format='{{.Config.WorkingDir}}' "$PARENT_IMAGE" 2>/dev/null || true)
# Default to /src if WORKDIR is empty
if [ -z "$WORKDIR" ]; then
    WORKDIR="/src"
fi
echo "Extracting source from $PARENT_IMAGE:$WORKDIR to repo.tar.gz..."
docker run --rm -v "$TARBALL_DIR:/tarballs" "$PARENT_IMAGE" \
    sh -c "cd '$WORKDIR' && tar -cvzf /tarballs/repo.tar.gz ."

# Create project.tar.gz from oss-fuzz project files
echo "Creating project.tar.gz from libs/oss-fuzz/projects/$PROJECT_NAME/..."
cd /crs-multilang/libs/oss-fuzz/projects && tar -cvzf "$TARBALL_DIR/project.tar.gz" "$PROJECT_NAME" && cd /crs-multilang

# Step 4: Build fuzzers using run.py build
echo ""
echo "[4/6] Building fuzzers via run.py build..."
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir "$TARBALL_DIR" \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification

# Step 5: Create fuzzers tarball
echo ""
echo "[5/6] Creating fuzzers.tar.gz from /out..."
cd /out && tar -cvzf "$TARBALL_DIR/fuzzers.tar.gz" --exclude=tarballs --exclude=images . && cd /crs-multilang

# Mark build as done
touch "$TARBALL_DIR/DONE"

# Step 6: Copy runtime images for runner
echo ""
echo "[6/6] Copying runtime images for runner..."
mkdir -p /out/images
cp "$CRS_CACHE_DIR/crs-multilang.tar.gz" /out/images/crs-multilang.tar.gz
cp "$CRS_CACHE_DIR/multilang-runner-joern.tar.gz" /out/images/joern.tar.gz
cp "$CRS_CACHE_DIR/redis.tar.gz" /out/images/redis.tar.gz

echo ""
echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
echo ""
echo "Tarballs in /out/tarballs/:"
ls -la /out/tarballs/
echo ""
echo "Images in /out/images/:"
ls -la /out/images/
