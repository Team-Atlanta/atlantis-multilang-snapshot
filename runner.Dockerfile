# DinD Runner for CRS-Multilang
# Uses cruizba/ubuntu-dind as base for nested Docker daemon
FROM cruizba/ubuntu-dind

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive \
    CRS_CACHE_DIR=/cache/images

RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages docker-compose pyyaml

WORKDIR /app

# Copy run scripts and compose files
COPY oss-crs-dind/run.sh /app/run.sh
COPY oss-crs-dind/docker-compose.yml /app/docker-compose.yml
COPY oss-crs-dind/docker-compose.mlla.yml /app/docker-compose.mlla.yml
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
