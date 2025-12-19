#!/bin/bash
set -eu

# Source config first for image arrays
source /crs-multilang/oss-crs-dind/config.sh

echo "=== CRS-Multilang Build Phase (DinD) ==="
echo "Using parent image: $PARENT_IMAGE"
echo "Project name: $PROJECT_NAME"
echo ""
echo "Docker data-root: /artifacts/docker-data (persisted to host)"

# Docker daemon is auto-started by cruizba/ubuntu-dind entrypoint
# With data-root=/artifacts/docker-data, Docker state persists to host
echo ""
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
    sleep 1
done
echo "Docker daemon ready"

# Create docker-data directory (Docker daemon may have already created it)
mkdir -p /artifacts/docker-data

cd /crs-multilang

# Step 1: Load CRS docker images from shared cache
echo ""
echo "[1/5] Loading CRS images..."

# Check if images are already available (from previous build or volume mode)
IMAGES_AVAILABLE=true
for img in "${DOCKER_IMAGES_BUILDER[@]}"; do
    if ! docker image inspect "$img" > /dev/null 2>&1; then
        IMAGES_AVAILABLE=false
        break
    fi
done

if [ "$IMAGES_AVAILABLE" = true ]; then
    echo "  Images already available (persisted from previous build or volume mode)"
    for img in "${DOCKER_IMAGES_BUILDER[@]}"; do
        echo "  ✓ $img"
    done
else
    echo "  Loading from tarballs (/cache/images/)..."
    /crs-multilang/oss-crs-dind/load-cache.sh all
fi

# Step 2: Load the project image from tarball (provided by oss-crs)
echo ""
echo "[2/5] Loading project image from /project-image.tar..."
docker load -i /project-image.tar

# Step 3: Prepare tarballs for run.py build
echo ""
echo "[3/5] Preparing tarballs..."
TARBALL_DIR=/artifacts/tarballs
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

# Copy aixcc config if it exists (required by init_codeindexer for MLLA mode)
AIXCC_CONFIG="/crs-multilang/libs/oss-fuzz/projects/$PROJECT_NAME/.aixcc/config.yaml"
if [ -f "$AIXCC_CONFIG" ]; then
    echo "Copying aixcc config from project..."
    cp "$AIXCC_CONFIG" "$TARBALL_DIR/aixcc_conf.yaml"
else
    echo "WARNING: No .aixcc/config.yaml found in project. Creating minimal default..."
    cat > "$TARBALL_DIR/aixcc_conf.yaml" << AIXCC_EOF
cp_name: "${PROJECT_NAME}"
full_mode:
  base_commit: ""
AIXCC_EOF
fi

# Step 4: Build fuzzers using run.py build
echo ""
echo "[4/5] Building fuzzers via run.py build..."
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
echo "[5/5] Creating fuzzers.tar.gz from /out..."
cd /out && tar -cvzf "$TARBALL_DIR/fuzzers.tar.gz" . && cd /crs-multilang

# Mark build as done
touch "$TARBALL_DIR/DONE"

# Note: No need to export images as tarballs anymore
# Docker data (including all images) persists in /artifacts/docker-data/
# The run phase will use the same Docker data directly

echo ""
echo "=== Build complete ==="
echo "Output in /out/:"
ls -la /out/
echo ""
echo "Tarballs in /artifacts/tarballs/:"
ls -la /artifacts/tarballs/
echo ""
echo "Docker data persisted in /artifacts/docker-data/"
echo "Size: $(du -sh /artifacts/docker-data 2>/dev/null | cut -f1 || echo 'calculating...')"
echo ""
echo "Available images for run phase:"
docker images --format "  ✓ {{.Repository}}:{{.Tag}} ({{.Size}})"
