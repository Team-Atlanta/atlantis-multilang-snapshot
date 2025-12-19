# DinD Runner for CRS-Multilang
# Uses cruizba/ubuntu-dind as base for nested Docker daemon
FROM cruizba/ubuntu-dind

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive

# Configure Docker to use /artifacts/docker-data as data root
# This reuses Docker state (images, layers) from the build phase
RUN mkdir -p /etc/docker && \
    echo '{"data-root": "/artifacts/docker-data"}' > /etc/docker/daemon.json

RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl pigz \
    && rm -rf /var/lib/apt/lists/*

# Note: Docker Compose v2 is built into Docker (docker compose), no Python package needed
RUN pip3 install --break-system-packages pyyaml

WORKDIR /app

# Copy run scripts and compose files
COPY oss-crs-dind/config.sh /app/config.sh
COPY oss-crs-dind/run.sh /app/run.sh
COPY oss-crs-dind/docker-compose.yml /app/docker-compose.yml
COPY oss-crs-dind/docker-compose.mlla.yml /app/docker-compose.mlla.yml
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
