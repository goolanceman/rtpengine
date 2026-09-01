#!/bin/bash
# Test daemon only — alternate ports / table / spool. Never touches production.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${BIN_DIR:-}" ]]; then
  BIN="$(cd "${BIN_DIR}" && pwd)"
elif [[ -f "${ROOT}/.bin-dir" ]]; then
  BIN="$(cd "$(cat "${ROOT}/.bin-dir")" && pwd)"
else
  BIN="$(cd "${ROOT}/../bins" && pwd)"
fi
export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

TABLE="${TABLE:-44}"

# Prefer env override, then primary src IP (not AWS metadata — siprec may lack it).
detect_ip() {
  if [[ -n "${LOCAL_IP:-}" ]]; then
    echo "$LOCAL_IP"
    return
  fi
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

LOCAL_IP="$(detect_ip)"
PUBLIC_IP="${PUBLIC_IP:-$LOCAL_IP}"

if [[ -z "$LOCAL_IP" ]]; then
  echo "FATAL: could not detect LOCAL_IP (set LOCAL_IP=...)" >&2
  exit 1
fi
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
if [[ ! -d "/proc/rtpengine/${TABLE}" ]]; then
  echo "FATAL: kernel table ${TABLE} not present after add" >&2
  ls -la /proc/rtpengine/ >&2 || true
  exit 1
fi

mkdir -p /var/spool/recording-test-12.5/{metadata,pcaps,tmp,wav}
chmod -R a+rwx /var/spool/recording-test-12.5 2>/dev/null || true

# Interface style matches siprec prod (private/IP + public/IP, no !advert).
echo "INFO: BIN=${BIN}" >&2
echo "INFO: LOCAL_IP=${LOCAL_IP} PUBLIC_IP=${PUBLIC_IP} TABLE=${TABLE}" >&2
echo "INFO: starting test rtpengine on NG 127.0.0.1:23222 RTP 61000-62998" >&2

exec "${BIN}/rtpengine" \
  --interface "private/${LOCAL_IP}" \
  --interface "public/${LOCAL_IP}" \
  --listen-ng=127.0.0.1:23222 \
  --listen-http=127.0.0.1:18080 \
  --listen-udp=127.0.0.1:13222 \
  --listen-cli=127.0.0.1:19900 \
  --table="${TABLE}" \
  --pidfile /run/rtpengine-test-12.5.pid \
  --port-min 61000 \
  --port-max 62998 \
  --recording-dir /var/spool/recording-test-12.5 \
  --recording-method proc \
  --log-level 5 \
  --log-stderr \
  --delete-delay 0 \
  --foreground
