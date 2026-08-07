#!/bin/bash
# Test recording-daemon only. Never touches production.
# Launched via bash so SELinux can exec bins living under $HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${BIN_DIR:-}" ]]; then
  BIN="$(cd "${BIN_DIR}" && pwd)"
elif [[ -f "${ROOT}/.bin-dir" ]]; then
  BIN="$(cd "$(cat "${ROOT}/.bin-dir")" && pwd)"
else
  BIN="$(cd "${ROOT}/../bins" && pwd)"
fi
export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
INI="${ROOT}/rtpengine-recording-test.ini"

if [[ ! -x "${BIN}/rtpengine-recording" ]]; then
  echo "FATAL: missing ${BIN}/rtpengine-recording" >&2
  exit 1
fi
if [[ ! -f "${INI}" ]]; then
  echo "FATAL: missing ${INI}" >&2
  exit 1
fi

mkdir -p /var/spool/recording-test-12.5 /tmp/recordings-test-12.5
chmod -R a+rwx /var/spool/recording-test-12.5 /tmp/recordings-test-12.5 || true

exec "${BIN}/rtpengine-recording" \
  --config-file="${INI}" \
  --foreground
