# OSS-CRS DinD (Docker-in-Docker) Integration

This directory contains scripts for running CRS-multilang using Docker-in-Docker with complete isolation from the host Docker environment.

## Overview

The DinD approach uses a nested Docker daemon inside containers. This provides:

1. **Complete isolation** - CRS containers are fully isolated from host Docker
2. **Simple cleanup** - When outer container stops, all nested containers die automatically
3. **Portable** - Works anywhere with Docker (no special host access needed)

## How It Works

Docker data is persisted to `/artifacts/docker-data/` which maps to a per-project directory on the host. This eliminates the need to export/import image tarballs between build and run phases.

```
Build Phase                              Run Phase
┌─────────────────────┐                 ┌─────────────────────┐
│ DinD Container      │                 │ DinD Container      │
│                     │                 │                     │
│ dockerd --data-root │                 │ dockerd --data-root │
│ /artifacts/docker-  │                 │ /artifacts/docker-  │
│ data/               │                 │ data/               │
└─────────┬───────────┘                 └─────────┬───────────┘
          │                                       │
          ▼                                       ▼
┌─────────────────────────────────────────────────────────────┐
│ Host: build/artifacts/crs-multilang/<project>/docker-data/  │
│                                                             │
│ ├── overlay2/     (layer data)                              │
│ ├── image/        (image metadata)                          │
│ └── ...           (Docker state)                            │
└─────────────────────────────────────────────────────────────┘
```

### Build Phase Flow

1. Docker daemon starts with `data-root=/artifacts/docker-data/`
2. Load CRS images from shared cache (`/cache/images/*.tar.gz`)
3. Build fuzzers
4. Docker state persists to `/artifacts/docker-data/` on host

### Run Phase Flow

1. Docker daemon starts with `data-root=/artifacts/docker-data/`
2. Images already available from build phase (no loading needed)
3. Run the fuzzer

## Volume Mount Architecture

Understanding how volumes are mounted is critical for DinD mode. The key insight is that **nested Docker uses container paths, not host paths**.

### Mount Chain: Host → DinD → Nested Containers

```
HOST FILESYSTEM
├── build/artifacts/crs-multilang-dind/<project>/
│   ├── tarballs/           # Build artifacts (repo.tar.gz, project.tar.gz, etc.)
│   └── docker-data/        # Docker daemon state
├── build/out/crs-multilang-dind/<project>/
│   └── (fuzzer outputs)
└── build/work/crs-multilang-dind/<project>/
    └── (working files)
        │
        │  oss-crs compose.yaml.j2 mounts these to DinD container
        ▼
DinD CONTAINER (outer)
├── /artifacts/              ← mounted from host build/artifacts/.../
│   ├── tarballs/
│   └── docker-data/
├── /out/                    ← mounted from host build/out/.../
└── /work/                   ← mounted from host build/work/.../
        │
        │  oss-crs-dind/docker-compose.yml mounts to nested containers
        ▼
NESTED CRS CONTAINER (inner)
├── /tarballs/               ← mounted from DinD's /artifacts/tarballs
├── /out/                    ← mounted from DinD's /out
└── /artifacts/              ← mounted from DinD's /artifacts
```

### Why Container Paths (Not Host Paths)?

In DinD mode, the nested Docker daemon runs **inside** the outer container and shares its filesystem. This is different from `host_docker_builder` mode:

| Mode | Docker Daemon Location | Path Type |
|------|------------------------|-----------|
| `host_docker_builder` | On HOST machine | Must use HOST paths (`/home/.../build/...`) |
| `dind` | Inside DinD container | Must use container paths (`/artifacts`, `/out`) |

**DinD mode**: The nested Docker daemon sees the DinD container's filesystem, so paths like `/artifacts/tarballs` are directly accessible.

**host_docker_builder mode**: The Docker daemon is on the host, so it cannot see container overlay paths. It needs absolute host paths like `/home/user/oss-crs/build/artifacts/.../`.

### Volume Configuration

1. **oss-crs (compose.yaml.j2)** automatically mounts host paths to DinD container:
   ```yaml
   volumes:
     - {{ build_dir }}/artifacts/{{ crs.name }}/{{ project }}:/artifacts
     - {{ build_dir }}/out/{{ crs.name }}/{{ project }}:/out
     - {{ build_dir }}/work/{{ crs.name }}/{{ project }}:/work
   ```

2. **config-crs.yaml** can specify additional volumes (like cache):
   ```yaml
   volumes:
     - ${HOST_CACHE_DIR}:/cache/images:ro
   ```

3. **docker-compose.yml** (inside DinD) mounts from container paths:
   ```yaml
   volumes:
     - /artifacts/tarballs:/tarballs:ro    # Container path, NOT ${HOST_*}
     - /out:/out
     - /artifacts:/artifacts
   ```

### Data Flow Example

**Build Phase**:
1. oss-crs copies source to WORKDIR (`/workspace`) of DinD builder
2. `build.sh` creates `repo.tar.gz` from `/workspace`
3. `build.sh` creates `project.tar.gz` from oss-fuzz project files
4. `run.py build` builds fuzzers, outputs to `/out/`

**Run Phase**:
1. Nested CRS container mounts `/artifacts/tarballs` as `/tarballs`
2. `get_cp` extracts tarballs to `/src/` and `/src/repo/`
3. CRS runs fuzzing with source at `/src/`

## Quick Start

### 1. Build CRS Images (One-Time, ~60-90 minutes)

```bash
cd oss-crs-dind
./prepare-cache.sh
```

This builds all CRS images in your host Docker.

### 2. Prepare Shared Cache

```bash
./prepare-cache.sh
```

Creates `.tar.gz` files in `/tmp/crs-multilang-dind-cache/` (~18GB). This is a shared cache used by all projects.

### 3. Configure oss-crs

Set the cache directory in your `.env`:

```bash
HOST_CACHE_DIR=/tmp/crs-multilang-dind-cache
```

### 4. Verify Cache (Optional)

```bash
./verify-cache.sh
```

## Directory Structure

```
oss-crs-dind/
├── config.sh              # Image names and cache configuration
├── prepare-cache.sh       # Build CRS images and prepare cache
├── verify-cache.sh        # Verify images/cache are available
├── load-cache.sh          # Load tarballs (used by build.sh)
├── build.sh               # Build phase script (runs inside builder container)
├── run.sh                 # Run phase script (runs inside runner container)
├── docker-compose.yml     # Fuzzing-only mode
├── docker-compose.mlla.yml # MLLA mode (with codeindexer, joern, lsp)
├── builder.Dockerfile     # Builder container definition
├── runner.Dockerfile      # Runner container definition
└── cache/
    └── images/            # Shared tarball cache
```

## Environment Variables

### Cache Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CRS_CACHE_DIR` | `/cache/images` (container) | Path to tarball cache inside DinD container |
| `HOST_CACHE_DIR` | `/tmp/crs-multilang-dind-cache` | Host path mounted to /cache/images in container |

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

## CRS Images

All images are defined in `config.sh`:

| Image | Purpose |
|-------|---------|
| `crs-multilang:latest` | Main CRS runtime |
| `multilang-runner-joern:latest` | Joern code analysis |
| `redis:latest` | Redis for CRS |
| `multilang-clang:latest` | Clang toolchain |
| `multilang-builder:latest` | C/C++ builder |
| `multilang-builder-jvm:latest` | JVM builder |
| `multilang-c-archive:latest` | C/C++ archive tools |
| `multilang-jvm-archive:latest` | JVM archive tools |
| `multilang-lsp-base:latest` | LSP base image |

## Artifacts Directory Structure

```
/artifacts/                    # Maps to build/artifacts/crs-multilang/<project>/
├── docker-data/               # Docker daemon data (persisted between phases)
│   ├── overlay2/              # Layer storage
│   ├── image/                 # Image metadata
│   └── ...                    # Other Docker state
├── tarballs/                  # Build artifacts
│   ├── repo.tar.gz
│   ├── project.tar.gz
│   ├── fuzzers.tar.gz
│   └── aixcc_conf.yaml
├── povs/                      # POV files (created by runner)
├── corpus/                    # Corpus files (created by runner)
└── crs-data/                  # CRS runtime data (created by runner)
    ├── workdir_result/        # Full workdir backup
    └── eval_result/           # Evaluation results
```

## MLLA Mode

For MLLA (LLM-assisted) fuzzing, set `CRS_INPUT_GENS` to include `mlla`:

```bash
CRS_INPUT_GENS=given_fuzzer,mlla
LITELLM_URL=http://your-llm-service
LITELLM_KEY=your-api-key
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

### "Image not found" during run phase

This usually means the build phase didn't complete successfully. Check:
1. Build phase logs for errors
2. `/artifacts/docker-data/` exists and contains data
3. Run `docker images` inside the runner to see available images

If images are missing, the runner will attempt to load from `/cache/images/` as a fallback.

### Out of disk space

- Shared cache: ~18GB in `/tmp/crs-multilang-dind-cache/`
- Per-project Docker data: ~15-20GB in `artifacts/<project>/docker-data/`
- Build output also needs space

Consider cleaning up old project artifacts:
```bash
rm -rf build/artifacts/crs-multilang/<project>/docker-data
```

## Comparison with Other Modes

| Aspect | Host Docker Socket | DinD (data-root) |
|--------|-------------------|------------------|
| Docker Daemon | On HOST | Inside container |
| Path Type | HOST paths (`/home/.../build/...`) | Container paths (`/artifacts`, `/out`) |
| Isolation | None (shares host Docker) | Full (own Docker daemon) |
| Build → Run transition | N/A | Instant (data persisted) |
| Host Docker | Required | Not used |
| Cleanup | Manual | Automatic (stop container) |
| Portability | Limited | High |
| Per-project isolation | No | Yes |
| `HOST_*` env vars | Required | Not used |
| Best for | Quick testing | Production, isolation |

## Design Notes

### Why Data-Root Persistence?

Previous approaches had drawbacks:

1. **Tarball export/import**: Required saving/loading ~18GB of images between build and run phases (~5-10 min overhead)
2. **Volume mounting at /var/lib/docker**: Required special oss-crs configuration and pre-populated volumes
3. **Copying Docker data**: Slow and doubles storage usage

The `data-root` approach:
- Docker stores data directly to `/artifacts/docker-data/` (host bind mount)
- Build phase populates the data
- Run phase sees it immediately (no copying, no loading)
- Per-project isolation via separate artifacts directories

### Filesystem Requirements

The host's `build/artifacts/` directory must be on a filesystem that supports Docker's overlay2 storage driver:
- **Recommended**: ext4, XFS (with ftype=1)
- **Not supported**: NFS, CIFS, GPFS, or nested overlayfs

### Shared Cache vs Per-Project Data

- **Shared cache** (`/cache/images/`): Contains all CRS images as tarballs, mounted read-only
- **Per-project data** (`/artifacts/docker-data/`): Project-specific Docker state, includes images + build cache

On first build, images are loaded from shared cache into per-project Docker data. Subsequent builds/runs use the persisted data.
