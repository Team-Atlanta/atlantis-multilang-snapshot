# CRS-Multilang OSS-CRS Integration Notes

This document summarizes the findings, bugs, fixes, and challenges encountered when integrating CRS-multilang with OSS-CRS.

## Overview

CRS-multilang uses a host Docker socket architecture for both build and run phases, which required careful handling of path mappings between containers and the host filesystem.

---

## Key Challenges

### 1. Host Docker Socket Path Mapping

**Problem:** When using host Docker socket from within a container, volume mount paths must be host paths, not container paths.

```
Builder Container                    Host Docker Daemon
┌─────────────────────┐              ┌─────────────────────┐
│ /work/artifacts/... │──docker run──│ Looks for           │
│ (exists here)       │   -v /work.. │ /work/artifacts/... │
│                     │              │ (doesn't exist!)    │
└─────────────────────┘              └─────────────────────┘
```

**Solution:** Implemented path conversion in `helper.py` using `HOST_WORK_DIR` and `HOST_OUT_DIR` environment variables to translate container paths to host paths for Docker volume mounts.

**Files Modified:**
- `libs/oss-fuzz/infra/helper.py` - Added `_to_host_path()` function
- `run.py` - Added `to_host_path()` method and path conversion logic

### 2. Build Output Separation (HOST_OUT_SUBDIR)

**Problem:** Different build types (main, symcc, coverage, lsp) were overwriting each other's outputs when stored in the same directory.

**Solution:** Added `HOST_OUT_SUBDIR` mechanism to create separate output directories for each build type.

```python
# Example: symcc build uses separate output
HOST_OUT_SUBDIR=symcc → outputs to HOST_OUT_DIR/symcc/
```

**Files Modified:**
- `run.py` - Added `HOST_OUT_SUBDIR` handling in `__run_build()`
- `oss-crs/build.sh` - Exports `HOST_OUT_SUBDIR` for symcc/coverage/lsp builds
- `libs/oss-fuzz/infra/helper.py` - Reads `HOST_OUT_SUBDIR` and adjusts paths

### 3. Docker Network Isolation

**Problem:** Multiple concurrent fuzzing runs had container name and network collisions.

**Solution:**
- Use project-scoped networks (`crs-internal`) for Redis/Joern isolation
- Unique container names using `${SAFE_TARGET}_${SAFE_HARNESS}` pattern
- Sanitize names to handle special characters

**Files Modified:**
- `oss-crs/docker-compose.yml` - Added network configuration
- `oss-crs/run.sh` - Added `sanitize_name()` function and network setup

### 4. Results/Output Storage

**Problem:** Fuzzing results (corpus, POVs, coverage) were lost when containers exited because `/crs-workdir` was not mounted.

**Solution:**
- Mount `HOST_ARTIFACT_DIR` to `/artifacts` in container
- Copy results from `/crs-workdir` to `/artifacts` at end of run
- Added `CRS_SKIP_SAVE` option to disable if needed

**Files Modified:**
- `oss-crs/docker-compose.yml` - Added `/artifacts` volume mount
- `bin/run_crs` - Added result saving logic
- `oss-crs/run.sh` - Pass through `CRS_SKIP_SAVE`

---

## Bugs Fixed

### Bug 1: Source Path Not Found in Nested Docker Build

**Symptom:** `clang: error: no such file or directory: '/src/mock-c/mock.c'`

**Root Cause:** Volume mount used container path (`/work/...`) instead of host path when building with host Docker socket.

**Fix:** Convert paths using `_to_host_path()` before passing to Docker.

### Bug 2: Redis URL Parsing Error

**Symptom:** CRS couldn't connect to Redis service.

**Root Cause:** Redis URL was being parsed incorrectly when service names were used.

**Fix:** Use Docker network service discovery with fixed URLs like `redis://redis:6379`.

### Bug 3: Container Name Collision

**Symptom:** `container name already in use` errors when running multiple instances.

**Root Cause:** All instances used same container names (`redis`, `joern`, `crs`).

**Fix:** Append `${SAFE_TARGET}_${SAFE_HARNESS}` to container names.

### Bug 4: `.aixcc/` Directory Missing

**Symptom:** Test metadata not present in build output.

**Root Cause:** `.aixcc/` is only copied when `CRS_TEST=True`, which is only set for test builds.

**Status:** Not a bug - intentional behavior. `.aixcc/` contains evaluation metadata only needed for test mode.

---

## Configuration Changes

### Environment Variables Added

| Variable | Purpose |
|----------|---------|
| `HOST_WORK_DIR` | Host path for `/work` directory mapping |
| `HOST_OUT_DIR` | Host path for `/out` directory mapping |
| `HOST_ARTIFACT_DIR` | Host path for artifacts (tarballs, results) |
| `HOST_OUT_SUBDIR` | Subdirectory for build type separation |
| `CRS_SKIP_SAVE` | Skip saving results to `/artifacts` |
| `CRS_EXTERNAL_NETWORK` | External network name for LiteLLM |

### Docker Compose Changes

```yaml
volumes:
  - ${HOST_ARTIFACT_DIR:-/out}/tarballs:/tarballs:ro   # Build artifacts
  - ${HOST_ARTIFACT_DIR:-/out}:/artifacts              # Results output
  - ${HOST_OUT_DIR:-/out}:/out                         # Build output

environment:
  - CRS_SKIP_SAVE=${CRS_SKIP_SAVE:-}

networks:
  crs-internal:    # Project-scoped, isolated
  crs-external:    # Shared for LiteLLM
```

---

## OSS-CRS Repository Changes

The following changes were made to the OSS-CRS repository:

### 1. Example Config (.env)

**File:** `example_configs/crs-multilang/.env`

Added:
```bash
# Skip saving results (povs, corpus, workdir) to /artifacts/
# Set to "True" to disable saving results (default: save results)
#CRS_SKIP_SAVE=True
```

### 2. Future Work (render_compose.py)

To fully support `skip_save` from config-crs.yaml, OSS-CRS's `render_compose.py` needs to:
1. Read `skip_save` option from config-crs.yaml
2. Set `CRS_SKIP_SAVE` environment variable when launching runner

Currently, `CRS_SKIP_SAVE` must be set manually in `.env` or environment.

---

## Output Structure

### Build Artifacts (`HOST_ARTIFACT_DIR/tarballs/`)

```
tarballs/
├── repo.tar.gz       # Project source code
├── project.tar.gz    # OSS-Fuzz project files
└── fuzzers.tar.gz    # Built fuzzer binaries
```

### Fuzzing Results (`HOST_ARTIFACT_DIR/`)

```
HOST_ARTIFACT_DIR/
├── tarballs/              # Build artifacts
├── povs/{harness}/        # POV files
├── corpus/{harness}/      # Corpus from uniafl_corpus
├── workdir_result/        # Full workdir copy
│   └── {harness}/
│       ├── uniafl_corpus/
│       ├── uniafl_cov/
│       ├── pov/
│       ├── others_corpus/
│       └── uniafl/
├── eval_result/           # (if EVAL_SEC > 0)
└── crs.config.{harness}   # Runtime config
```

---

## Naming Conventions

| Container Path | Host Path | Notes |
|----------------|-----------|-------|
| `/artifacts` | `HOST_ARTIFACT_DIR` | Plural for consistency |
| `/tarballs` | `HOST_ARTIFACT_DIR/tarballs` | Read-only mount |
| `/out` | `HOST_OUT_DIR` | Build outputs |
| `/work` | `HOST_WORK_DIR` | Build working directory |
| `/crs-workdir` | (internal) | Runtime workdir, not mounted |

---

## Testing Checklist

- [ ] Build completes without path errors
- [ ] Multiple concurrent runs don't collide
- [ ] Results are saved to `HOST_ARTIFACT_DIR`
- [ ] `CRS_SKIP_SAVE=True` disables result saving
- [ ] Symcc/coverage/lsp builds use separate directories
- [ ] Redis and Joern services are accessible

---

## Commit Summary

### CRS-Multilang Repository

```
9c9a2a96d refactor: rename /artifact to /artifacts for consistency with host path
942d49dcb feat(oss-crs): pass CRS_SKIP_SAVE from run.sh to docker-compose
1a80da369 feat(oss-crs): add CRS_SKIP_SAVE env var to docker-compose
ed5f3f195 feat: save fuzzing results to /artifacts/ by default in run_crs
85b4ab59d feat(oss-crs): add /artifacts volume mount for results storage
66c958100 feat: add HOST_OUT_SUBDIR for coverage/symcc/lsp build separation
b577ee649 fix(oss-crs): add network isolation and fix Redis URL parsing
```

### OSS-CRS Repository

```
936dc50 refactor: rename /artifact to /artifacts in comment for consistency
a8bc8b3 feat(crs-multilang): add CRS_SKIP_SAVE option to example config
```
