#!/bin/bash
# Install 12.5.1.31 rich-log USERSPACE only. Keeps existing 12.5 kernel module.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${ROOT}/.." && pwd)"

# Bins resolution (first match wins):
#   1) BIN_DIR=... env
#   2) $ROOT/bins          (debian-bins package layout if script is copied there)
#   3) release-bins/.../debian  (git checkout on siprec)
#   4) $REPO/debian-bins/bins
if [[ -n "${BIN_DIR:-}" ]]; then
  BIN_DIR="$(cd "${BIN_DIR}" && pwd)"
elif [[ -x "${ROOT}/bins/rtpengine" ]]; then
  BIN_DIR="${ROOT}/bins"
elif [[ -x "${REPO}/release-bins/12.5.1.31-rich-logs/debian/rtpengine" ]]; then
  BIN_DIR="${REPO}/release-bins/12.5.1.31-rich-logs/debian"
elif [[ -x "${REPO}/debian-bins/bins/rtpengine" ]]; then
  BIN_DIR="${REPO}/debian-bins/bins"
else
  echo "ERROR: no binaries found. Set BIN_DIR= to debian rtpengine dir." >&2
  echo "  e.g. BIN_DIR=\$PWD/release-bins/12.5.1.31-rich-logs/debian sudo -E $0" >&2
  exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "==> script: $ROOT"
echo "==> bins:   $BIN_DIR"
echo "==> version: $(cat "${BIN_DIR}/../VERSION" 2>/dev/null || cat "$ROOT/VERSION" 2>/dev/null || echo unknown) sha=$(cat "${BIN_DIR}/../GIT_SHA" 2>/dev/null || cat "$ROOT/GIT_SHA" 2>/dev/null || echo unknown)"
echo "==> host kernel: $(uname -r)"
echo "==> USERSPACE ONLY — kernel module not touched"
echo "==> THIS STOPS AND REPLACES PRODUCTION rtpengine + rtpengine-recording"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need systemctl
need install

[[ -x "${BIN_DIR}/rtpengine" ]] || { echo "missing ${BIN_DIR}/rtpengine" >&2; exit 1; }
[[ -x "${BIN_DIR}/rtpengine-recording" ]] || { echo "missing ${BIN_DIR}/rtpengine-recording" >&2; exit 1; }

DAEMON_PATH="$(command -v rtpengine || true)"
REC_PATH="$(command -v rtpengine-recording || true)"
[[ -n "$DAEMON_PATH" ]] || DAEMON_PATH=/usr/bin/rtpengine
[[ -n "$REC_PATH" ]] || REC_PATH=/usr/bin/rtpengine-recording
[[ -x /usr/sbin/rtpengine-recording ]] && REC_PATH=/usr/sbin/rtpengine-recording

TS=$(date +%Y%m%d%H%M%S)
BAK_DIR="/var/backups/rtpengine-rich-logs/${TS}"
mkdir -p "${BAK_DIR}"

echo "==> backup existing bins BEFORE stop (mandatory)"
backup_one() {
  local src="$1" name="$2"
  if [[ -e "$src" ]]; then
    cp -a "$src" "${BAK_DIR}/${name}"
    # also leave a sibling .bak.TS next to original for quick rollback
    cp -a "$src" "${src}.bak.${TS}"
    ls -la "${BAK_DIR}/${name}" "${src}.bak.${TS}"
  else
    echo "NOTE: no existing $name at $src"
  fi
}
backup_one "$DAEMON_PATH" rtpengine
backup_one "$REC_PATH" rtpengine-recording
# capture unit files + start scripts if present
for f in /etc/systemd/system/rtpengine.service          /etc/systemd/system/rtpengine-recording.service          /lib/systemd/system/rtpengine.service          /lib/systemd/system/rtpengine-recording.service          /usr/local/libexec/rtpengine-start.sh          /etc/rtpengine.conf          /etc/rtpengine-recording.ini; do
  [[ -e "$f" ]] && cp -a "$f" "${BAK_DIR}/$(basename "$f")" || true
done
echo "${DAEMON_PATH}" > "${BAK_DIR}/DAEMON_PATH.txt"
echo "${REC_PATH}" > "${BAK_DIR}/REC_PATH.txt"
echo "Backup dir: ${BAK_DIR}"
ls -la "${BAK_DIR}"

echo "==> stopping services"
systemctl stop rtpengine rtpengine-recording 2>/dev/null || true
sleep 1
pkill -x rtpengine 2>/dev/null || true
pkill -x rtpengine-recording 2>/dev/null || true

echo "==> install userspace -> $DAEMON_PATH / $REC_PATH"
install -m 755 "${BIN_DIR}/rtpengine" "$DAEMON_PATH"
install -m 755 "${BIN_DIR}/rtpengine-recording" "$REC_PATH"
file "$DAEMON_PATH" "$REC_PATH"
grep -ao 'recording DETECT' "$DAEMON_PATH" | head -1 || echo "WARN: DETECT log string missing" >&2
grep -ao 'status=SAVED' "$REC_PATH" | head -1 || echo "WARN: SAVED log string missing" >&2

echo "==> kernel module (unchanged — expect xt_RTPENGINE 12.5)"
lsmod | grep -iE 'rtp|RTP' || echo "WARN: no rtp module loaded yet"
if [[ ! -e /proc/rtpengine/control ]]; then
  echo "==> loading existing package module xt_RTPENGINE"
  modprobe xt_RTPENGINE 2>/dev/null || true
fi
ls -la /proc/rtpengine/control || {
  echo "ERROR: /proc/rtpengine/control missing — install/load 12.5 kernel package first" >&2
  exit 1
}

echo "==> start services"
systemctl start rtpengine-recording
systemctl start rtpengine
sleep 2
systemctl is-active rtpengine rtpengine-recording
ls /proc/rtpengine/ || true

echo
echo "Done. Watch logs:"
echo "  journalctl -u rtpengine -u rtpengine-recording -f | grep recording"
echo "Rollback:"
echo "  systemctl stop rtpengine rtpengine-recording"
echo "  cp -a ${DAEMON_PATH}.bak.${TS} ${DAEMON_PATH}"
echo "  cp -a ${REC_PATH}.bak.${TS} ${REC_PATH}"
echo "  # or from full backup dir: ${BAK_DIR}"
echo "  systemctl start rtpengine-recording rtpengine"
