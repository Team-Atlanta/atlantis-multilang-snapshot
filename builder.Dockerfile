# DinD Builder for CRS-Multilang
# Uses cruizba/ubuntu-dind as base for nested Docker daemon
FROM cruizba/ubuntu-dind

ARG parent_image
ARG CRS_TARGET
ENV PARENT_IMAGE=${parent_image}
ENV PROJECT_NAME=${CRS_TARGET}

ENV TZ=US \
    DEBIAN_FRONTEND=noninteractive

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

# Set WORKDIR to /workspace (oss-crs will copy project source here)
WORKDIR /workspace

# Copy and setup build script
COPY oss-crs-dind/build.sh /build.sh
RUN chmod +x /build.sh

CMD ["/build.sh"]
