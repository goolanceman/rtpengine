#!/usr/bin/env bash
# Build Linux rtpengine + rtpengine-recording binaries via Docker and extract them
# into the Debian build output dir: build-tools/bins/debian/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

BIN_ROOT="${ROOT_DIR}/build-tools/bins"
OUT_DIR="${BIN_ROOT}/debian"
BACKUP_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DOCKERFILE="${ROOT_DIR}/Dockerfile"
IMAGE_DAEMON="${IMAGE_DAEMON:-rtpengine-localbuild:daemon}"
IMAGE_RECORDING="${IMAGE_RECORDING:-rtpengine-localbuild:recording}"
LOG_DIR="${ROOT_DIR}/build-tools/logs"

backup_existing_bins() {
  if [[ -d "${OUT_DIR}" ]] && find "${OUT_DIR}" -mindepth 1 -print -quit | grep -q .; then
    local backup_dir="${BIN_ROOT}/debian_backup_${BACKUP_TIMESTAMP}"
    mkdir -p "${backup_dir}"
    shopt -s dotglob nullglob
    local existing=("${OUT_DIR}"/*)
    shopt -u dotglob nullglob
    mv -- "${existing[@]}" "${backup_dir}/"
    echo "==> backed up existing Debian binaries to ${backup_dir}"
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

echo "==> repo: ${ROOT_DIR}"
echo "==> branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "==> head:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "==> out:    ${OUT_DIR}"

echo "==> building daemon (target: rtpengine)"
docker build --target rtpengine -t "${IMAGE_DAEMON}" -f "${DOCKERFILE}" . \
  > "${LOG_DIR}/docker-build-daemon.log" 2>&1
echo "    ok (log: ${LOG_DIR}/docker-build-daemon.log)"

echo "==> building recording-daemon (target: rtpengine-recording)"
docker build --target rtpengine-recording -t "${IMAGE_RECORDING}" -f "${DOCKERFILE}" . \
  > "${LOG_DIR}/docker-build-recording.log" 2>&1
echo "    ok (log: ${LOG_DIR}/docker-build-recording.log)"

echo "==> extracting binaries"
docker rm -f rtpengine-extract-daemon rtpengine-extract-recording >/dev/null 2>&1 || true
docker create --name rtpengine-extract-daemon "${IMAGE_DAEMON}" >/dev/null
docker create --name rtpengine-extract-recording "${IMAGE_RECORDING}" >/dev/null
docker cp rtpengine-extract-daemon:/usr/local/bin/rtpengine \
  "${OUT_DIR}/rtpengine"
docker cp rtpengine-extract-recording:/usr/local/bin/rtpengine-recording \
  "${OUT_DIR}/rtpengine-recording"
docker rm -f rtpengine-extract-daemon rtpengine-extract-recording >/dev/null 2>&1 || true
chmod +x "${OUT_DIR}/rtpengine" "${OUT_DIR}/rtpengine-recording"

{
  echo "EXTRACT OK $(date)"
  echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "head=$(git rev-parse --short HEAD 2>/dev/null || true)"
  ls -la "${OUT_DIR}"
  file "${OUT_DIR}"/* 2>/dev/null || true
} | tee "${LOG_DIR}/extract.txt"

echo
echo "Done. Binaries:"
echo "  ${OUT_DIR}/rtpengine"
echo "  ${OUT_DIR}/rtpengine-recording"
echo
echo "Note: these are Linux binaries (architecture matches your Docker engine),"
echo "not native macOS Mach-O executables."
