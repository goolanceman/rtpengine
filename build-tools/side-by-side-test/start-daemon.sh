#!/bin/bash
# Test daemon only — alternate ports / table / spool. Never touches production.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Prefer BIN_DIR from env, then .bin-dir written by run-test.sh install-units, else ../bins
if [[ -n "${BIN_DIR:-}" ]]; then
  BIN="$(cd "${BIN_DIR}" && pwd)"
elif [[ -f "${ROOT}/.bin-dir" ]]; then
  BIN="$(cd "$(cat "${ROOT}/.bin-dir")" && pwd)"
else
  BIN="$(cd "${ROOT}/../bins" && pwd)"
fi
export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

TABLE=44
LOCAL_IP=$(curl -s --connect-timeout 1 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s --connect-timeout 1 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "$LOCAL_IP")

if [[ ! -x "${BIN}/rtpengine" ]]; then
  echo "FATAL: missing ${BIN}/rtpengine" >&2
  exit 1
fi
if [[ ! -e /proc/rtpengine/control ]]; then
  echo "FATAL: /proc/rtpengine/control missing (load 12.5 xt_RTPENGINE first)" >&2
  exit 1
fi

# Create table 44 if needed; do NOT del production tables
echo "add ${TABLE}" > /proc/rtpengine/control 2>/dev/null || true

exec "${BIN}/rtpengine" \
  --interface "private/${LOCAL_IP}" \
  --interface "public/${LOCAL_IP}!${PUBLIC_IP}" \
  --listen-ng=127.0.0.1:23222 \
  --listen-http=127.0.0.1:18080 \
  --listen-udp=127.0.0.1:13222 \
  --listen-cli=127.0.0.1:19900 \
  --table="${TABLE}" \
  --pidfile /run/rtpengine-test-12.5.pid \
  --port-min 40000 \
  --port-max 42000 \
  --recording-dir /var/spool/recording-test-12.5 \
  --recording-method proc \
  --log-level 5 \
  --delete-delay 0 \
  --foreground
