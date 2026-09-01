#!/usr/bin/env bash
# Build EL8/RHEL8-compatible rtpengine + rtpengine-recording via Docker and extract
# into the RHEL build output dir: build-tools/bins/rhel/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

BIN_ROOT="${ROOT_DIR}/build-tools/bins"
OUT_DIR="${BIN_ROOT}/rhel"
BACKUP_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.rhel8"
IMAGE_BUILD="${IMAGE_BUILD:-rtpengine-rhel8-build:local}"
IMAGE_BINARIES="${IMAGE_BINARIES:-rtpengine-rhel8-binaries:local}"
LOG_DIR="${ROOT_DIR}/build-tools/logs"
WITH_TRANSCODING="${WITH_TRANSCODING:-yes}"

backup_existing_bins() {
  if [[ -d "${OUT_DIR}" ]] && find "${OUT_DIR}" -mindepth 1 -print -quit | grep -q .; then
    local backup_dir="${BIN_ROOT}/rhel_backup_${BACKUP_TIMESTAMP}"
    mkdir -p "${backup_dir}"
    shopt -s dotglob nullglob
    local existing=("${OUT_DIR}"/*)
    shopt -u dotglob nullglob
    mv -- "${existing[@]}" "${backup_dir}/"
    echo "==> backed up existing RHEL binaries to ${backup_dir}"
  fi
}

backup_existing_bins
mkdir -p "${OUT_DIR}" "${LOG_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required but not found in PATH" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "error: docker daemon is not running" >&2
  exit 1
fi

echo "==> repo:   ${ROOT_DIR}"
echo "==> branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "==> head:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "==> out:    ${OUT_DIR}"
echo "==> df:     ${DOCKERFILE}"
echo "==> transc: ${WITH_TRANSCODING}"

echo "==> building RHEL8 image (target: build)"
docker build \
  --target build \
  --build-arg "WITH_TRANSCODING=${WITH_TRANSCODING}" \
  -t "${IMAGE_BUILD}" \
  -f "${DOCKERFILE}" \
  . > "${LOG_DIR}/docker-build-rhel8.log" 2>&1
echo "    ok (log: ${LOG_DIR}/docker-build-rhel8.log)"

echo "==> extracting binaries"
docker rm -f rtpengine-rhel8-extract >/dev/null 2>&1 || true
docker create --name rtpengine-rhel8-extract "${IMAGE_BUILD}" >/dev/null
docker cp rtpengine-rhel8-extract:/out/rtpengine "${OUT_DIR}/rtpengine"
if docker cp rtpengine-rhel8-extract:/out/rtpengine-recording \
    "${OUT_DIR}/rtpengine-recording" 2>/dev/null; then
  :
else
  echo "warning: rtpengine-recording not produced (transcoding disabled?)" >&2
fi
docker rm -f rtpengine-rhel8-extract >/dev/null 2>&1 || true
chmod +x "${OUT_DIR}/rtpengine" || true
chmod +x "${OUT_DIR}/rtpengine-recording" 2>/dev/null || true

{
  echo "EXTRACT OK $(date)"
  echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "head=$(git rev-parse --short HEAD 2>/dev/null || true)"
  ls -la "${OUT_DIR}"
  file "${OUT_DIR}"/* 2>/dev/null || true
  echo "--- host ldd rtpengine ---"
  ldd "${OUT_DIR}/rtpengine" 2>&1 | head -40 || true
  if [[ -x "${OUT_DIR}/rtpengine-recording" ]]; then
    echo "--- host ldd rtpengine-recording ---"
    ldd "${OUT_DIR}/rtpengine-recording" 2>&1 | head -40 || true
  fi
  "${OUT_DIR}/rtpengine" --version 2>&1 || true
  [[ -x "${OUT_DIR}/rtpengine-recording" ]] && \
    "${OUT_DIR}/rtpengine-recording" --version 2>&1 || true
} | tee "${LOG_DIR}/extract-rhel8.txt"

echo
echo "Done. Binaries:"
echo "  ${OUT_DIR}/rtpengine"
[[ -x "${OUT_DIR}/rtpengine-recording" ]] && \
  echo "  ${OUT_DIR}/rtpengine-recording"
