#!/bin/bash
# CRS Docker Cache Configuration for DinD
#
# This file provides default configuration for the CRS image caching system.
# Users can override settings via environment variables.

# Cache directory - user configurable via environment
# Default: oss-crs-dind/cache/images/ relative to this script
if [ -z "${CRS_CACHE_DIR:-}" ]; then
    CRS_CACHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache/images"
fi
export CRS_CACHE_DIR

# Base builder images (built by multilang-all.sh)
# Build order matters: multilang-clang -> multilang-builder -> multilang-builder-jvm
BASE_BUILDER_IMAGES=(
    "multilang-clang.tar.gz"
    "multilang-builder.tar.gz"
    "multilang-builder-jvm.tar.gz"
)
export BASE_BUILDER_IMAGES

# Archive images (built by run.py build_crs, FROM base builder images)
ARCHIVE_IMAGES=(
    "multilang-c-archive.tar.gz"
    "multilang-jvm-archive.tar.gz"
)
export ARCHIVE_IMAGES

# CRS runtime images
CRS_IMAGES=(
    "crs-multilang.tar.gz"
    "multilang-lsp-base.tar.gz"
    "multilang-runner-joern.tar.gz"
    "redis.tar.gz"
)
export CRS_IMAGES

# All required images for build/run (complete list)
REQUIRED_IMAGES=(
    "${BASE_BUILDER_IMAGES[@]}"
    "${ARCHIVE_IMAGES[@]}"
    "${CRS_IMAGES[@]}"
)
export REQUIRED_IMAGES

# Runtime images needed by runner (subset of above)
RUNTIME_IMAGES=(
    "crs-multilang.tar.gz"
    "multilang-runner-joern.tar.gz"
    "redis.tar.gz"
)
export RUNTIME_IMAGES
