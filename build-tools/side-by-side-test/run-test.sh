#!/bin/bash
# Side-by-side test of 12.5 rich-log bins. NEVER stops/replaces production.
# sudo bash run-test.sh {install-units|start|smoke|logs|status|stop|uninstall-units}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "${ROOT}/.." && pwd)"
# BIN_DIR: directory containing rtpengine + rtpengine-recording.
# Default = package bins/ (Debian glibc). On RHEL lab use:
#   BIN_DIR=/path/to/rhel-binaries-12.5.1.31 sudo -E bash run-test.sh ...
BIN="${BIN_DIR:-${PKG}/bins}"
BIN="$(cd "${BIN}" && pwd)"
UNIT_DIR=/etc/systemd/system
PROD_D=rtpengine.service
PROD_R=rtpengine-recording.service
TEST_D=rtpengine-test.service
TEST_R=rtpengine-recording-test.service
NG_HOST=127.0.0.1
NG_PORT=23222
TABLE=44
SPOOL=/var/spool/recording-test-12.5
OUTDIR=/tmp/recordings-test-12.5

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ $(id -u) -eq 0 ]] || die "run as root: sudo $0 $*"; }

assert_prod() {
  systemctl is-active --quiet "$PROD_D" 2>/dev/null && echo "OK prod $PROD_D active" || echo "NOTE: prod $PROD_D not active"
  systemctl is-active --quiet "$PROD_R" 2>/dev/null && echo "OK prod $PROD_R active" || true
}

check_bins() {
  [[ -x "${BIN}/rtpengine" ]] || die "missing ${BIN}/rtpengine (set BIN_DIR=...)"
  [[ -x "${BIN}/rtpengine-recording" ]] || die "missing ${BIN}/rtpengine-recording (set BIN_DIR=...)"
  # Fail fast if libs clearly wrong for this host (e.g. Debian bins on EL8)
  if ! LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
      ldd "${BIN}/rtpengine" >/tmp/rtpengine-test-ldd.out 2>&1; then
    cat /tmp/rtpengine-test-ldd.out >&2 || true
    die "ldd failed for ${BIN}/rtpengine — wrong OS/glibc package? (Debian bins need Debian host)"
  fi
  if grep -q 'not found' /tmp/rtpengine-test-ldd.out; then
    grep 'not found' /tmp/rtpengine-test-ldd.out >&2 || true
    die "missing shared libs for ${BIN}/rtpengine — use matching OS binaries (BIN_DIR=...)"
  fi
  echo "OK bins from ${BIN}"
}

prep() {
  mkdir -p "${SPOOL}"/{metadata,pcaps,tmp,wav} "${OUTDIR}"
  chmod -R a+rwx "${SPOOL}" "${OUTDIR}" || true
  [[ -e /proc/rtpengine/control ]] || modprobe xt_RTPENGINE 2>/dev/null || true
  [[ -e /proc/rtpengine/control ]] || die "no /proc/rtpengine/control"
  echo "add ${TABLE}" > /proc/rtpengine/control 2>/dev/null || true
}

cmd_install_units() {
  need_root install-units
  check_bins
  chmod +x "${ROOT}/start-daemon.sh" "${ROOT}/start-recording.sh" \
    "${ROOT}/run-test.sh" "${ROOT}/smoke-ng.py"
  # Persist BIN path for start-daemon.sh and units
  printf '%s\n' "${BIN}" > "${ROOT}/.bin-dir"
  sed -e "s|__ROOT__|${ROOT}|g" -e "s|__BIN__|${BIN}|g" \
    "${ROOT}/rtpengine-test.service" > "${UNIT_DIR}/${TEST_D}"
  sed -e "s|__ROOT__|${ROOT}|g" -e "s|__BIN__|${BIN}|g" \
    "${ROOT}/rtpengine-recording-test.service" > "${UNIT_DIR}/${TEST_R}"
  systemctl daemon-reload
  echo "Installed test units only (prod units unchanged). BIN=${BIN}"
  assert_prod
}

cmd_start() {
  need_root start
  systemctl cat "$TEST_D" >/dev/null 2>&1 || die "run: sudo $0 install-units"
  prep
  systemctl start "$TEST_R"
  sleep 1
  systemctl start "$TEST_D"
  sleep 2
  systemctl is-active "$TEST_D" "$TEST_R"
  assert_prod
  echo "Test NG ${NG_HOST}:${NG_PORT} table=${TABLE} spool=${SPOOL}"
  echo "Next: sudo $0 smoke"
}

cmd_stop() {
  need_root stop
  systemctl stop "$TEST_D" "$TEST_R" 2>/dev/null || true
  echo "Test units stopped."; assert_prod
}

cmd_status() {
  echo "=== production ==="
  systemctl is-active "$PROD_D" 2>/dev/null || echo inactive
  systemctl is-active "$PROD_R" 2>/dev/null || echo inactive
  echo "=== test ==="
  systemctl is-active "$TEST_D" 2>/dev/null || echo inactive
  systemctl is-active "$TEST_R" 2>/dev/null || echo inactive
  ls -la /proc/rtpengine/ 2>/dev/null || true
  ss -tulnp 2>/dev/null | grep -E '23222|18080|19900|13222|22222|8080|12222|9900' || true
  echo "test RTP ports: 61000-62998 (prod uses 40000-60000)"
  assert_prod
}

cmd_logs() { journalctl -u "$TEST_D" -u "$TEST_R" -n "${1:-80}" --no-pager; }

cmd_smoke() {
  need_root smoke
  systemctl is-active --quiet "$TEST_D" || die "start test first"
  systemctl is-active --quiet "$TEST_R" || die "start test first"
  python3 "${ROOT}/smoke-ng.py"
  echo "=== rich logs (TEST units only) ==="
  journalctl -u "$TEST_D" -u "$TEST_R" --since "2 min ago" --no-pager \
    | grep -E 'recording (DETECT|START|STOP|FINISH|FILE|STREAM|NEW|INFO|FLAG)' | tail -60 || true
  journalctl -u "$TEST_D" --since "2 min ago" --no-pager | grep -q 'recording DETECT' \
    || die "no recording DETECT — wrong instance or missing logs"
  journalctl -u "$TEST_D" --since "2 min ago" --no-pager | grep -q 'recording START' \
    || die "no recording START"
  echo "SMOKE PASSED"; assert_prod
  echo "Promote when ready: sudo $0 stop && sudo $0 uninstall-units && cd ${PKG} && sudo bash install-on-debian-siprec.sh"
}

cmd_uninstall() {
  need_root uninstall-units
  systemctl stop "$TEST_D" "$TEST_R" 2>/dev/null || true
  systemctl disable "$TEST_D" "$TEST_R" 2>/dev/null || true
  rm -f "${UNIT_DIR}/${TEST_D}" "${UNIT_DIR}/${TEST_R}"
  systemctl daemon-reload
  echo "Removed test units only."; assert_prod
}

case "${1:-help}" in
  install-units) cmd_install_units ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  logs) shift; cmd_logs "${1:-80}" ;;
  smoke) cmd_smoke ;;
  uninstall-units) cmd_uninstall ;;
  *) echo "Usage: sudo $0 {install-units|start|smoke|logs|status|stop|uninstall-units}" ;;
esac
