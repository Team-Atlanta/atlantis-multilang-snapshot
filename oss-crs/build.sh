#!/bin/bash
set -eu

echo "=== CRS-Multilang Build Phase ==="
echo "Using parent image: $PARENT_IMAGE"
echo "Project name: $PROJECT_NAME"

cd /crs-multilang

# Step 1: Load pre-built CRS docker images from cache (instead of rebuilding)
echo "Loading cached CRS images..."
source /crs-multilang/oss-crs/config.sh
/crs-multilang/oss-crs/verify-cache.sh
/crs-multilang/oss-crs/load-cache.sh

# Step 2: Load the project image from tarball (provided by oss-crs)
echo "Loading project image from /project-image.tar..."
docker load -i /project-image.tar

# Step 3: Prepare tarballs for run.py build
# Use /out/tarballs since /out is the mounted volume that persists
echo "Preparing tarballs..."
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

# oss-fuzz.tar.gz NOT needed (libs/oss-fuzz already exists in crs-multilang)

# Step 4: Build fuzzers using run.py build
echo "Building fuzzers via run.py build..."
# Note: SKIP_IMAGE_PULL will be added to run.py later to skip registry pull
python3 run.py build \
    --target "$PROJECT_NAME" \
    --tar-dir "$TARBALL_DIR" \
    --out-dir /out \
    --focus "" \
    --registry local \
    --image-version latest \
    --skip-symcc-verification

# Step 5: Create tarballs that get_cp expects
echo "Creating tarballs for CRS runner..."

# Create fuzzers.tar.gz from compiled fuzzers in /out
echo "Creating fuzzers.tar.gz from /out..."
cd /out && tar -cvzf "$TARBALL_DIR/fuzzers.tar.gz" . && cd /crs-multilang

# Create empty project.tar.gz (oss-crs already provides project via parent image)
mkdir -p /tmp/empty_project
touch /tmp/empty_project/.placeholder
cd /tmp/empty_project && tar -cvzf "$TARBALL_DIR/project.tar.gz" . && cd /crs-multilang

# Mark build as done
touch "$TARBALL_DIR/DONE"

# Step 6: Prepare images for runner (all from cache)
echo "Preparing images for runner..."
mkdir -p /out/images
cp "$CRS_CACHE_DIR/crs-multilang.tar.gz" /out/images/crs-multilang.tar.gz
cp "$CRS_CACHE_DIR/multilang-runner-joern.tar.gz" /out/images/joern.tar.gz
cp "$CRS_CACHE_DIR/redis.tar.gz" /out/images/redis.tar.gz

echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
echo "Tarballs in /out/tarballs/:"
ls -la /out/tarballs/
echo "Images in /out/images/:"
ls -la /out/images/
