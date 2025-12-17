FROM ubuntu:22.04

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive

# Install Python, Docker CLI (no daemon - uses host docker socket)
RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl ca-certificates gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update -y \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install pyyaml

WORKDIR /app
COPY oss-crs/run.sh /app/run.sh
COPY oss-crs/docker-compose.yml /app/docker-compose.yml
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
