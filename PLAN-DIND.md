# DinD (Docker-in-Docker) Support Plan

## Overview

Add DinD support as an alternative to the current host docker socket approach. DinD uses pre-built image caches that are loaded into a nested Docker daemon, providing complete isolation.

## Architecture Comparison

| Aspect | Host Socket (`oss-crs/`) | DinD (`oss-crs-dind/`) |
|--------|--------------------------|------------------------|
| Docker daemon | Host's daemon | Nested daemon inside container |
| Image caching | Host layer cache | Pre-exported tar files |
| Build speed | Fast (layer cache) | Medium (tar load) |
| Isolation | Shared with host | Complete isolation |
| Cleanup sidecar | Needed (monitors containers) | Not needed (all dies together) |
| Complexity | Lower | Higher (daemon management) |

## Directory Structure

```
crs-multilang-public/
├── oss-crs/                  # Host docker socket approach (existing)
│   ├── build.sh
│   ├── run.sh
│   ├── docker-compose.yml
│   ├── docker-compose.mlla.yml
│   ├── README.md
│   └── INTEGRATION.md
│
└── oss-crs-dind/             # NEW: DinD approach
    ├── config.sh             # Image list and cache directory settings
    ├── prepare-cache.sh      # One-time cache build (60-90 min)
    ├── load-cache.sh         # Parallel image loading
    ├── verify-cache.sh       # Verify cache completeness
    ├── build.sh              # DinD build phase
    ├── run.sh                # DinD run phase
    ├── docker-compose.yml    # Fuzzing-only (no cleanup sidecar)
    ├── docker-compose.mlla.yml # MLLA mode
    ├── builder.Dockerfile    # Builder with DinD base
    ├── runner.Dockerfile     # Runner with DinD base
    └── README.md             # DinD-specific documentation
```

## Implementation Details

### 1. config.sh - Cache Configuration

```bash
#!/bin/bash
# Cache directory (user configurable via environment)
CRS_CACHE_DIR="${CRS_CACHE_DIR:-$(dirname "$0")/cache/images}"

# Base builder images (build order matters)
BASE_BUILDER_IMAGES=(
    "multilang-clang.tar.gz"
    "multilang-builder.tar.gz"
    "multilang-builder-jvm.tar.gz"
)

# Archive images
ARCHIVE_IMAGES=(
    "multilang-c-archive.tar.gz"
    "multilang-jvm-archive.tar.gz"
)

# CRS runtime images
CRS_IMAGES=(
    "crs-multilang.tar.gz"
    "multilang-lsp-base.tar.gz"
    "multilang-runner-joern.tar.gz"
    "redis.tar.gz"
)

# All required images
REQUIRED_IMAGES=(
    "${BASE_BUILDER_IMAGES[@]}"
    "${ARCHIVE_IMAGES[@]}"
    "${CRS_IMAGES[@]}"
)
```

### 2. prepare-cache.sh - One-Time Cache Build

Steps:
1. Build all CRS images via `run.py build_crs --build-base-img`
2. Build joern service image
3. Pull redis image
4. Export all images to tar.gz files

Estimated time: 60-90 minutes (one-time)

### 3. load-cache.sh - Parallel Image Loading

- Support both `.tar` and `.tar.gz` formats
- Parallel loading (configurable MAX_PARALLEL)
- Auto-detect compression

### 4. build.sh - DinD Build Phase

Steps:
1. Start Docker daemon (via `start-docker.sh` from ubuntu-dind)
2. Load cached CRS images
3. Load project image from tarball
4. Extract source code
5. Build fuzzers via `run.py build`
6. Create output tarballs
7. Copy runtime images to `/out/images/`

### 5. run.sh - DinD Run Phase

Steps:
1. Start Docker daemon
2. Load images from `/out/images/`
3. Generate crs.config
4. Start services via docker-compose
5. Wait for completion (no cleanup sidecar needed)

### 6. docker-compose.yml - Simplified (No Cleanup Sidecar)

```yaml
version: '3.8'

services:
  redis:
    image: redis:latest
    command: redis-server --appendonly yes
    networks:
      - crs-network

  crs:
    image: crs-multilang:latest
    privileged: true
    environment:
      - TARBALL_DIR=/tarballs
      - CRS_CONFIG=/crs.config
      - DICTGEN_REDIS_URL=redis://redis:6379
      # ... other env vars
    volumes:
      - /out/tarballs:/tarballs:ro
      - /out:/out
      - /tmp/crs.config:/crs.config:ro
    depends_on:
      - redis
    networks:
      - crs-network
    command: ["run_crs"]

networks:
  crs-network:
    driver: bridge
```

Key differences from host socket version:
- **No cleanup sidecar** (DinD container death stops everything)
- No external network configuration
- Simpler volume mounts (no HOST_* path translation needed)

### 7. Dockerfiles

**builder.Dockerfile**:
```dockerfile
FROM cruizba/ubuntu-dind

ARG parent_image
ARG CRS_TARGET
ENV PARENT_IMAGE=${parent_image}
ENV PROJECT_NAME=${CRS_TARGET}
ENV CRS_CACHE_DIR=/cache/images

RUN apt-get update -y && apt-get install -y \
    git python3 python3-pip curl pigz rsync \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages coloredlogs pyyaml python-on-whales

COPY . /crs-multilang
COPY --from=project . /crs-multilang/libs/oss-fuzz/projects/${CRS_TARGET}/

WORKDIR /workspace

COPY oss-crs-dind/build.sh /build.sh
RUN chmod +x /build.sh

CMD ["/build.sh"]
```

**runner.Dockerfile**:
```dockerfile
FROM cruizba/ubuntu-dind

ENV CRS_CACHE_DIR=/cache/images

RUN apt-get update -y && apt-get install -y \
    python3 python3-pip curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages docker-compose pyyaml

WORKDIR /app
COPY oss-crs-dind/run.sh /app/run.sh
COPY oss-crs-dind/docker-compose.yml /app/docker-compose.yml
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
```

## Usage

### One-Time Setup (build cache)
```bash
cd oss-crs-dind
./prepare-cache.sh
# Takes 60-90 minutes, creates ~15GB of cached images
```

### Build Phase
```bash
docker build -t crs-builder-dind -f oss-crs-dind/builder.Dockerfile .

docker run --privileged --rm \
  -v ${CRS_CACHE_DIR}:/cache/images:ro \
  -v /path/to/project-image.tar:/project-image.tar:ro \
  -v /path/to/out:/out \
  -e PROJECT_NAME=myproject \
  -e PARENT_IMAGE=gcr.io/oss-fuzz/myproject \
  crs-builder-dind
```

### Run Phase
```bash
docker build -t crs-runner-dind -f oss-crs-dind/runner.Dockerfile .

docker run --privileged --rm \
  -v /path/to/out:/out \
  -e CPUSET_CPUS=0-7 \
  -e MEMORY_LIMIT=16G \
  crs-runner-dind my_harness_name
```

## Comparison: When to Use Which

| Scenario | Recommended |
|----------|-------------|
| Local development | `oss-crs/` (host socket) |
| CI with shared Docker | `oss-crs/` (host socket) |
| Complete isolation needed | `oss-crs-dind/` |
| No host Docker access | `oss-crs-dind/` |
| Kubernetes/isolated runners | `oss-crs-dind/` |

## Implementation Order

1. Create `oss-crs-dind/` directory
2. Add `config.sh` with image configuration
3. Add `prepare-cache.sh` for one-time cache build
4. Add `verify-cache.sh` and `load-cache.sh`
5. Add `builder.Dockerfile` and `build.sh`
6. Add `runner.Dockerfile` and `run.sh`
7. Add `docker-compose.yml` (fuzzing-only, no cleanup sidecar)
8. Add `docker-compose.mlla.yml` (with MLLA services, no cleanup sidecar)
9. Add `README.md` with documentation
10. Test end-to-end

## Testing Checklist

- [ ] `prepare-cache.sh` builds all images successfully
- [ ] `verify-cache.sh` validates cache completeness
- [ ] `load-cache.sh` loads images in parallel
- [ ] Builder container builds fuzzers correctly
- [ ] Runner container runs fuzzing session
- [ ] MLLA mode works with codeindexer, joern, lsp
- [ ] Results are saved to `/out` correctly
- [ ] Container stop kills all nested services (no cleanup sidecar needed)
