# DinD Builder for CRS-Multilang
#
# This Dockerfile defines the build phase container for DinD mode.
# Key architecture points:
#
# 1. Uses cruizba/ubuntu-dind for nested Docker daemon
# 2. oss-crs copies source code to WORKDIR (/workspace) before running
# 3. build.sh creates tarballs from /workspace (source) and oss-fuzz project files
# 4. Docker state persists to /artifacts/docker-data for reuse by runner phase
#
# Volume mount chain:
#   Host: build/artifacts/.../  →  DinD: /artifacts/  (includes docker-data/, tarballs/)
#   Host: build/out/.../        →  DinD: /out/
#   Host: build/work/.../       →  DinD: /work/
#
FROM cruizba/ubuntu-dind

ARG parent_image
ARG CRS_TARGET
ENV PARENT_IMAGE=${parent_image}
ENV PROJECT_NAME=${CRS_TARGET}

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive

# Configure Docker daemon:
# - data-root: Persist Docker state to per-project artifacts directory
# - dns: Use Google DNS for reliable external registry access (ghcr.io, etc.)
RUN mkdir -p /etc/docker && \
    echo '{"data-root": "/artifacts/docker-data", "dns": ["8.8.8.8", "8.8.4.4"]}' > /etc/docker/daemon.json

# Install Python and dependencies for run.py
RUN apt-get update -y && apt-get install -y \
    git python3 python3-pip curl pigz rsync \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages coloredlogs pyyaml python-on-whales

# Copy full crs-multilang source
# Note: Cache is excluded via .dockerignore and mounted at runtime
COPY . /crs-multilang

# Copy oss-fuzz project files from additional_contexts (provided by oss-crs)
COPY --from=project . /crs-multilang/libs/oss-fuzz/projects/${CRS_TARGET}/

# Cache mounted at runtime via volumes: ${CRS_CACHE_DIR}:/cache/images:ro
ENV CRS_CACHE_DIR=/cache/images

# Set WORKDIR to /workspace
# IMPORTANT: oss-crs copies source code to this directory before running the container.
# build.sh extracts repo.tar.gz from $(pwd) which will be /workspace.
WORKDIR /workspace

# Use build script directly from /crs-multilang/oss-crs-dind/
# (already copied via COPY . /crs-multilang)
RUN chmod +x /crs-multilang/oss-crs-dind/build.sh

CMD ["/crs-multilang/oss-crs-dind/build.sh"]
