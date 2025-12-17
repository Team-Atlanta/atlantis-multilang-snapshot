# OSS-CRS Docker-in-Docker Integration

This directory contains scripts for running CRS-multilang in a Docker-in-Docker (DinD) environment with image caching to avoid expensive rebuilds.

## Overview

The CRS-multilang system requires multiple Docker images that take 60-90 minutes to build from scratch. This integration provides:

1. **One-time cache preparation** - Build all images once and export to tar files
2. **Fast per-project builds** - Load cached images in DinD, only build project-specific fuzzers (~5-10 min)
3. **Reproducible runs** - Use pre-built images for consistent fuzzing execution

## Quick Start

### 1. Prepare the Image Cache (One-time, ~60-90 min)

```bash
cd /path/to/afc-crs-multilang-snapshot
./oss-crs/prepare-cache.sh
```

This builds and exports all required images to `oss-crs/cache/images/`.

### 2. Build Fuzzers for a Project

```bash
# Cache is baked into the image during build (via COPY . /crs-multilang)
docker build -t crs-builder -f builder.Dockerfile .

docker run --privileged \
  -v /path/to/project-image.tar:/project-image.tar:ro \
  -v /path/to/out:/out \
  -e PROJECT_NAME=myproject \
  -e PARENT_IMAGE=gcr.io/oss-fuzz/myproject \
  crs-builder
```

### 3. Run Fuzzing

```bash
docker build -t crs-runner -f runner.Dockerfile .

docker run --privileged \
  -v /path/to/out:/out \
  -e CPUSET_CPUS=0-7 \
  -e MEMORY_LIMIT=16G \
  crs-runner my_harness_name
```

## Directory Structure

```
oss-crs/
├── README.md           # This file
├── config.sh           # Configuration (cache location, image lists)
├── prepare-cache.sh    # One-time: build and export all images
├── verify-cache.sh     # Validate cache completeness
├── load-cache.sh       # Load cached images into Docker
├── build.sh            # Build phase script (runs inside DinD)
├── run.sh              # Run phase script (runs inside DinD)
├── docker-compose.yml  # Service orchestration for runtime
└── cache/
    └── images/         # Cached image tarballs (created by prepare-cache.sh)
        ├── multilang-clang.tar.gz
        ├── multilang-builder.tar.gz
        ├── multilang-builder-jvm.tar.gz
        ├── multilang-c-archive.tar.gz
        ├── multilang-jvm-archive.tar.gz
        ├── crs-multilang.tar.gz
        ├── multilang-lsp-base.tar.gz
        ├── multilang-runner-joern.tar.gz
        ├── redis.tar.gz
        └── manifest.json
```

## Cached Images

| Image | Size (Est.) | Purpose |
|-------|-------------|---------|
| `multilang-clang` | ~3 GB | Base LLVM/Clang with custom fuzzer runtime |
| `multilang-builder` | ~5 GB | C/C++ build environment |
| `multilang-builder-jvm` | ~4 GB | JVM build environment |
| `multilang-c-archive` | ~2 GB | C/C++ build artifacts |
| `multilang-jvm-archive` | ~2 GB | JVM build artifacts |
| `crs-multilang` | ~15 GB | Main CRS fuzzing engine |
| `multilang-lsp-base` | ~3 GB | Language server base |
| `multilang-runner-joern` | ~4 GB | Joern code analysis service |
| `redis` | ~100 MB | State/cache storage |

**Total cache size: ~15-20 GB** (gzip compressed, ~50% savings)

## Configuration

### Cache Location

By default, images are cached in `oss-crs/cache/images/`. Override with:

```bash
export CRS_CACHE_DIR=/path/to/custom/cache
./oss-crs/prepare-cache.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CRS_CACHE_DIR` | `oss-crs/cache/images/` | Location for cached image tarballs |
| `PROJECT_NAME` | (required) | OSS-Fuzz project name |
| `PARENT_IMAGE` | (required) | Docker image with project source |
| `CPUSET_CPUS` | `0-7` | CPU cores for fuzzing |
| `MEMORY_LIMIT` | `16G` | Memory limit for fuzzing |
| `LITELLM_URL` | (optional) | LLM service URL |
| `LITELLM_KEY` | (optional) | LLM service API key |

## Scripts

### prepare-cache.sh

Builds all base images and exports them to the cache directory. Run once on the host machine.

**What it builds:**
1. All CRS images via `run.py build_crs --build-base-img` (includes base builders + CRS images)
2. Pulls `redis:latest`

Note: Joern is built per-project in `build.sh`, not cached here.

### verify-cache.sh

Checks that all required images exist in the cache. Returns non-zero if any are missing.

```bash
./oss-crs/verify-cache.sh
# Output: Cache verified OK
```

### load-cache.sh

Loads all cached images into Docker. Used inside DinD containers.

```bash
./oss-crs/load-cache.sh
# Output: All images loaded successfully
```

### build.sh

Main build script that runs inside the DinD builder container:
1. Loads cached images
2. Loads project image from tarball
3. Extracts source code
4. Builds fuzzers via `run.py build`
5. Copies images and tarballs to `/out/`

### run.sh

Run script that executes inside the DinD runner container:
1. Starts Docker daemon
2. Loads images from `/out/images/`
3. Generates CRS config
4. Starts services via docker-compose

## Troubleshooting

### Cache verification fails

```bash
./oss-crs/verify-cache.sh
# ERROR: Missing multilang-builder.tar.gz
```

**Solution:** Run `./oss-crs/prepare-cache.sh` to rebuild the cache.

### Build fails with "image not found"

Ensure the cache exists before building the Docker image:
```bash
# Cache must exist at oss-crs/cache/images/ before docker build
ls oss-crs/cache/images/*.tar.gz

# Rebuild the Docker image to include updated cache
docker build -t crs-builder -f builder.Dockerfile .
```

### Out of disk space

The cache requires ~18 GB (compressed). Check available space:
```bash
du -sh oss-crs/cache/images/
df -h .
```

## Performance

| Operation | Without Cache | With Cache | Savings |
|-----------|--------------|------------|---------|
| Initial setup | N/A | 60-90 min | One-time |
| Per-project build | 60-90 min | 5-10 min | ~85% |
| Image loading | N/A | 2-3 min | - |

## Updating the Cache

When CRS code changes, rebuild the cache:

```bash
# Remove old cache
rm -rf oss-crs/cache/images/*

# Rebuild
./oss-crs/prepare-cache.sh
```

The `manifest.json` file tracks when the cache was built and the git commit used.
