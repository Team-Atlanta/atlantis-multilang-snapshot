# DinD Runner for CRS-Multilang
#
# This Dockerfile defines the run phase container for DinD mode.
# Key architecture points:
#
# 1. Uses cruizba/ubuntu-dind for nested Docker daemon
# 2. Docker daemon uses same data-root (/artifacts/docker-data) as builder
# 3. All CRS images are already available from build phase (no loading needed)
# 4. run.sh starts nested Docker and runs CRS containers via docker-compose
#
# Volume mount chain:
#   Host: build/artifacts/.../  →  DinD: /artifacts/  →  Nested CRS: /tarballs/, /artifacts/
#   Host: build/out/.../        →  DinD: /out/        →  Nested CRS: /out/
#
# docker-compose.yml uses CONTAINER paths (e.g., /artifacts), NOT HOST paths.
# In DinD mode, nested Docker shares the outer container's filesystem.
#
FROM cruizba/ubuntu-dind

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive \
    CRS_CACHE_DIR=/cache/images

# Configure Docker daemon:
# - data-root: Reuse Docker state from build phase
# - dns: Use Google DNS for reliable external registry access (ghcr.io, etc.)
RUN mkdir -p /etc/docker && \
    echo '{"data-root": "/artifacts/docker-data", "dns": ["8.8.8.8", "8.8.4.4"]}' > /etc/docker/daemon.json

RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl pigz \
    && rm -rf /var/lib/apt/lists/*

# Note: Docker Compose v2 is built into Docker (docker compose), no Python package needed
RUN pip3 install --break-system-packages pyyaml

# Copy run scripts to /crs-runner/
COPY oss-crs-dind/ /crs-runner/
RUN chmod +x /crs-runner/run.sh

# Set WORKDIR to /workspace for consistency with builder
# Note: Runner primarily uses /artifacts/ for tarballs and /out/ for results
WORKDIR /workspace

ENTRYPOINT ["/crs-runner/run.sh"]
