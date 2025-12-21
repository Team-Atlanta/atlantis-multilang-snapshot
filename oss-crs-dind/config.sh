#!/bin/bash
# CRS Docker Image Configuration for DinD
#
# This file defines Docker image names and tarball filenames
# used by build.sh, run.sh, and other scripts.

# =============================================================================
# Cache Configuration
# =============================================================================

# Cache directory for tarball images
# - On host (prepare-cache.sh): defaults to /tmp/crs-multilang-dind-cache
# - In container: overridden by Dockerfile ENV to /cache/images
if [ -z "${CRS_CACHE_DIR:-}" ]; then
    CRS_CACHE_DIR="/tmp/crs-multilang-dind-cache"
fi
export CRS_CACHE_DIR

# =============================================================================
# Registry Configuration (for pulling images instead of loading tarballs)
# =============================================================================

# Container registry URL for pulling pre-built CRS images
# If set, load-cache.sh will pull from registry when tarballs are not available
# Default: ghcr.io/team-atlanta/atlantis-multilang-snapshot
CRS_REGISTRY="${CRS_REGISTRY:-ghcr.io/team-atlanta/atlantis-multilang-snapshot}"
export CRS_REGISTRY

# Docker volume name for pre-populated images (used by prepare-cache.sh --volume)
CRS_VOLUME_NAME="${CRS_VOLUME_NAME:-crs-multilang-images}"
export CRS_VOLUME_NAME

# =============================================================================
# Docker Image Names (for docker image inspect, docker save/load, etc.)
# =============================================================================

# All CRS images (complete list)
DOCKER_IMAGES_ALL=(
    "crs-multilang:latest"
    "multilang-runner-joern:latest"
    "redis:latest"
    "multilang-clang:latest"
    "multilang-builder:latest"
    "multilang-builder-jvm:latest"
    "multilang-c-archive:latest"
    "multilang-jvm-archive:latest"
    "multilang-lsp-base:latest"
)
export DOCKER_IMAGES_ALL

# Builder images required for build phase
DOCKER_IMAGES_BUILDER=(
    "multilang-clang:latest"
    "multilang-builder:latest"
    "multilang-builder-jvm:latest"
    "multilang-c-archive:latest"
    "multilang-jvm-archive:latest"
    "crs-multilang:latest"
    "multilang-lsp-base:latest"
    "multilang-runner-joern:latest"
    "redis:latest"
)
export DOCKER_IMAGES_BUILDER

# Runtime images required for run phase
DOCKER_IMAGES_RUNTIME=(
    "crs-multilang:latest"
    "multilang-runner-joern:latest"
    "redis:latest"
)
export DOCKER_IMAGES_RUNTIME

# =============================================================================
# Tarball Filenames (for load-cache.sh, verify-cache.sh)
# =============================================================================

# All required tarballs
REQUIRED_IMAGES=(
    "multilang-clang.tar.gz"
    "multilang-builder.tar.gz"
    "multilang-builder-jvm.tar.gz"
    "multilang-c-archive.tar.gz"
    "multilang-jvm-archive.tar.gz"
    "crs-multilang.tar.gz"
    "multilang-lsp-base.tar.gz"
    "multilang-runner-joern.tar.gz"
    "redis.tar.gz"
)
export REQUIRED_IMAGES

# Runtime tarballs
RUNTIME_IMAGES=(
    "crs-multilang.tar.gz"
    "multilang-runner-joern.tar.gz"
    "redis.tar.gz"
)
export RUNTIME_IMAGES

# =============================================================================
# Language-Specific Image Sets (for load-cache.sh)
# =============================================================================

# C/C++ builder images (skip JVM-specific)
BASE_BUILDER_IMAGES_C=(
    "multilang-clang.tar.gz"
    "multilang-builder.tar.gz"
)
export BASE_BUILDER_IMAGES_C

# C/C++ archive images
ARCHIVE_IMAGES_C=(
    "multilang-c-archive.tar.gz"
)
export ARCHIVE_IMAGES_C

# JVM builder images (skip C-specific clang)
BASE_BUILDER_IMAGES_JVM=(
    "multilang-builder-jvm.tar.gz"
)
export BASE_BUILDER_IMAGES_JVM

# JVM archive images
ARCHIVE_IMAGES_JVM=(
    "multilang-jvm-archive.tar.gz"
)
export ARCHIVE_IMAGES_JVM

# Common CRS images (needed by all languages)
CRS_IMAGES=(
    "crs-multilang.tar.gz"
    "multilang-lsp-base.tar.gz"
    "multilang-runner-joern.tar.gz"
    "redis.tar.gz"
)
export CRS_IMAGES

# =============================================================================
# Project-Specific Image Naming
# =============================================================================

# LSP runner image naming pattern
# Usage: LSP_IMAGE=$(get_lsp_image_name "project-name")
LSP_IMAGE_PREFIX="multilang-lsp-"
LSP_IMAGE_TARBALL="lsp-runner.tar.gz"
export LSP_IMAGE_PREFIX LSP_IMAGE_TARBALL

# Function to get LSP runner image name for a project
# Args: $1 = project name (will be sanitized)
get_lsp_image_name() {
    local project="$1"
    # Sanitize project name (replace / with _)
    local safe_project=$(echo "$project" | tr '/' '_')
    echo "${LSP_IMAGE_PREFIX}${safe_project}:latest"
}
export -f get_lsp_image_name
