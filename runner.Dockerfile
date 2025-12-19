# DinD Runner for CRS-Multilang
# Uses cruizba/ubuntu-dind as base for nested Docker daemon
FROM cruizba/ubuntu-dind

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive \
    CRS_CACHE_DIR=/cache/images

# Configure Docker to use /artifacts/docker-data as data root
# This reuses Docker state (images, layers) from the build phase
RUN mkdir -p /etc/docker && \
    echo '{"data-root": "/artifacts/docker-data"}' > /etc/docker/daemon.json

RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl pigz \
    && rm -rf /var/lib/apt/lists/*

# Note: Docker Compose v2 is built into Docker (docker compose), no Python package needed
RUN pip3 install --break-system-packages pyyaml

# Copy run scripts to /crs-runner/
COPY oss-crs-dind/ /crs-runner/
RUN chmod +x /crs-runner/run.sh

# Set WORKDIR to /workspace (oss-crs may copy data here)
WORKDIR /workspace

ENTRYPOINT ["/crs-runner/run.sh"]
