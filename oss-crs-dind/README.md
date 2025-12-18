# OSS-CRS DinD (Docker-in-Docker) Integration

This directory contains scripts for running CRS-multilang using Docker-in-Docker with pre-built image caches.

## Overview

The DinD approach uses a nested Docker daemon inside containers, with pre-exported image tarballs for fast loading. This provides:

1. **Complete isolation** - No interaction with host Docker daemon
2. **Portable caches** - Pre-built images can be distributed as tar files
3. **Simple cleanup** - When outer container stops, all nested containers die automatically
4. **No cleanup sidecar** - Unlike host socket mode, no need for monitoring containers

## Comparison with Host Socket Mode (`oss-crs/`)

| Aspect | Host Socket (`oss-crs/`) | DinD (`oss-crs-dind/`) |
|--------|--------------------------|------------------------|
| Docker daemon | Host's daemon | Nested daemon |
| Image caching | Host layer cache | Pre-exported tar files |
| Build speed | Fast (layer cache) | Medium (tar load) |
| Isolation | Shared with host | Complete |
| Cleanup | Needs sidecar | Automatic |
| Use case | CI with shared Docker | Isolated runners |

## Quick Start

### 1. Prepare Image Cache (One-Time, ~60-90 minutes)

```bash
cd oss-crs-dind
./prepare-cache.sh
```

This builds all CRS images and exports them to `cache/images/` (~15GB).

### 2. Verify Cache

```bash
./verify-cache.sh
```

### 3. Build Fuzzers

```bash
# Build builder image
docker build -t crs-builder-dind -f oss-crs-dind/builder.Dockerfile .

# Run build
docker run --privileged --rm \
  -v $(pwd)/oss-crs-dind/cache/images:/cache/images:ro \
  -v /path/to/project-image.tar:/project-image.tar:ro \
  -v /path/to/out:/out \
  -v /path/to/artifacts:/artifacts \
  -e PROJECT_NAME=myproject \
  -e PARENT_IMAGE=gcr.io/oss-fuzz/myproject \
  crs-builder-dind
```

### 4. Run Fuzzing

```bash
# Build runner image
docker build -t crs-runner-dind -f oss-crs-dind/runner.Dockerfile .

# Run fuzzing
docker run --privileged --rm \
  -v /path/to/out:/out \
  -v /path/to/artifacts:/artifacts \
  -e CPUSET_CPUS=0-7 \
  -e MEMORY_LIMIT=16G \
  crs-runner-dind my_harness_name
```

## Volume Structure

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| `/path/to/cache/images` | `/cache/images` | Pre-built image cache (build only) |
| `/path/to/out` | `/out` | Build outputs (fuzzers) |
| `/path/to/artifacts` | `/artifacts` | Tarballs + results (persistent) |

**Artifacts directory structure:**
```
/artifacts/
├── tarballs/          # Build artifacts (created by builder)
│   ├── repo.tar.gz
│   ├── project.tar.gz
│   ├── fuzzers.tar.gz
│   └── aixcc_conf.yaml
├── images/            # Runtime images (created by builder)
│   ├── crs-multilang.tar.gz
│   ├── joern.tar.gz
│   ├── redis.tar.gz
│   └── lsp-runner.tar.gz (if MLLA mode)
├── povs/              # POV files (created by runner)
├── corpus/            # Corpus files (created by runner)
└── workdir_result/    # Full workdir backup (created by runner)
```

## Directory Structure

```
oss-crs-dind/
├── config.sh              # Image list and cache directory configuration
├── prepare-cache.sh       # One-time cache build script
├── verify-cache.sh        # Verify cache completeness
├── load-cache.sh          # Parallel image loading
├── build.sh               # Build phase script (runs inside builder container)
├── run.sh                 # Run phase script (runs inside runner container)
├── docker-compose.yml     # Fuzzing-only mode
├── docker-compose.mlla.yml # MLLA mode (with codeindexer, joern, lsp)
├── builder.Dockerfile     # Builder container definition
├── runner.Dockerfile      # Runner container definition
└── cache/                 # Created by prepare-cache.sh
    └── images/            # Cached image tarballs
```

## Environment Variables

### Build Phase

| Variable | Required | Description |
|----------|----------|-------------|
| `PROJECT_NAME` | Yes | OSS-Fuzz project name |
| `PARENT_IMAGE` | Yes | Docker image with project source |

### Run Phase

| Variable | Default | Description |
|----------|---------|-------------|
| `CPUSET_CPUS` | `0-7` | CPU cores for fuzzing |
| `MEMORY_LIMIT` | `16G` | Memory limit |
| `CRS_INPUT_GENS` | `given_fuzzer` | Input generators (comma-separated) |
| `LITELLM_URL` | (empty) | LLM service URL |
| `LITELLM_KEY` | (empty) | LLM API key |
| `CRS_TARGET` | (empty) | Target project name |
| `CRS_NAME` | `crs-multilang` | CRS instance name |
| `CRS_SKIP_SAVE` | (empty) | Set to `True` to skip saving results |

## Cached Images

The cache includes:

**Base Builder Images:**
- `multilang-clang.tar.gz`
- `multilang-builder.tar.gz`
- `multilang-builder-jvm.tar.gz`

**Archive Images:**
- `multilang-c-archive.tar.gz`
- `multilang-jvm-archive.tar.gz`

**Runtime Images:**
- `crs-multilang.tar.gz`
- `multilang-lsp-base.tar.gz`
- `multilang-runner-joern.tar.gz`
- `redis.tar.gz`

## MLLA Mode

For MLLA (LLM-assisted) fuzzing, set `CRS_INPUT_GENS` to include `mlla`:

```bash
docker run --privileged --rm \
  -v /path/to/out:/out \
  -v /path/to/artifacts:/artifacts \
  -e CPUSET_CPUS=0-7 \
  -e MEMORY_LIMIT=16G \
  -e CRS_INPUT_GENS=given_fuzzer,mlla \
  -e LITELLM_URL=http://your-llm-service \
  -e LITELLM_KEY=your-api-key \
  crs-runner-dind my_harness_name
```

This will use `docker-compose.mlla.yml` which includes:
- `codeindexer` - Code indexing service (one-shot)
- `joern` - Code analysis service
- `lsp` - Language server protocol service
- `crs` - Main fuzzing engine

## Troubleshooting

### "Cannot connect to Docker daemon"

The container needs `--privileged` flag:
```bash
docker run --privileged ...
```

### "Image not found in cache"

Run `verify-cache.sh` to check cache status, then `prepare-cache.sh` to rebuild missing images.

### Slow image loading

Increase parallel loading:
```bash
MAX_PARALLEL=8 ./load-cache.sh
```

### Out of disk space

The cache requires ~15GB. The build output also needs space for tarballs and fuzzers.

## When to Use DinD vs Host Socket

**Use DinD (`oss-crs-dind/`) when:**
- You need complete isolation from host Docker
- Running in Kubernetes or isolated CI runners
- Host doesn't have Docker or you can't access it
- You want portable, self-contained builds

**Use Host Socket (`oss-crs/`) when:**
- You have access to host Docker daemon
- You want faster builds (layer caching)
- Running in CI with shared Docker infrastructure
- Simpler setup is preferred
