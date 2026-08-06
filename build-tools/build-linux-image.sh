#!/usr/bin/env bash
# Build a standard GNU/Linux rtpengine Docker image from the current checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build-tools/logs
LOG="build-tools/logs/docker-image-build.log"

BRANCH="$(git rev-parse --abbrev-ref HEAD | tr '/:' '--')"
SHA="$(git rev-parse --short HEAD)"
TAG_BRANCH="rtpengine:${BRANCH}-${SHA}"
TAG_LOCAL="rtpengine:local"
TAG_NOTIFY="rtpengine-recording-notify:local"

{
  echo "=== START $(date) ==="
  echo "repo=$ROOT"
  echo "branch=$(git rev-parse --abbrev-ref HEAD)"
  echo "head=$SHA"
  docker info 2>&1 | egrep 'Server Version|OSType|Architecture|Operating System' || true
  echo
  echo "Building standard Debian (trixie) GNU/Linux image via Dockerfile"
  echo "Tags: $TAG_BRANCH , $TAG_LOCAL , $TAG_NOTIFY"
  echo

  docker build \
    -f Dockerfile \
    -t "$TAG_BRANCH" \
    -t "$TAG_LOCAL" \
    -t "$TAG_NOTIFY" \
    .

  echo
  echo "BUILD_OK"
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}' | head -20

  echo
  echo "Sanity: rtpengine help"
  docker run --rm --entrypoint rtpengine "$TAG_LOCAL" --help 2>&1 | head -40 || true
  echo
  echo "Sanity: rtpengine-recording help"
  docker run --rm --entrypoint rtpengine-recording "$TAG_LOCAL" --help 2>&1 | head -40 || true

  echo "=== END $(date) ==="
} 2>&1 | tee "$LOG"
