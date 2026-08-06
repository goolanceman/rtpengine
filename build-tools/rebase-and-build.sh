#!/usr/bin/env bash
# Rebase current branch onto origin/master, then Docker-build binaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

LOG_DIR="${LOG_DIR:-${ROOT_DIR}/build-tools/logs}"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/rebase-and-build.log"

{
  echo "=== START $(date) ==="
  echo "repo=${ROOT_DIR}"
  echo "branch=$(git rev-parse --abbrev-ref HEAD)"
  echo "HEAD before=$(git rev-parse --short HEAD)"

  "${SCRIPT_DIR}/rebase-onto-master.sh"
  "${SCRIPT_DIR}/docker-build-binaries.sh"

  echo "=== DONE $(date) ==="
} | tee "${LOG}"
