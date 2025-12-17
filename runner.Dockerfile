FROM cruizba/ubuntu-dind

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive \
    CRS_CACHE_DIR=/cache/images

RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages docker-compose pyyaml

WORKDIR /app
COPY oss-crs/run.sh /app/run.sh
COPY oss-crs/docker-compose.yml /app/docker-compose.yml
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
