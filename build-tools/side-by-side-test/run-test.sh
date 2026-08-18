#!/bin/bash
# Side-by-side test of 12.5 rich-log bins. NEVER stops/replaces production.
# sudo bash run-test.sh {install-units|start|smoke|logs|status|stop|uninstall-units}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "${ROOT}/.." && pwd)"
# BIN resolved lazily in resolve_bin() so status/stop/logs work without BIN_DIR.
# Default bins: release-bins/12.5.1.31-rich-logs/{debian|rhel}  (see build-tools/BINS.md)
# Override: BIN_DIR=... sudo -E bash run-test.sh install-units
BIN=""
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

canonical_os_bins() {
  local id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release; echo "${ID_LIKE:-} ${ID:-}")"
  fi
  case " ${id} " in
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*ol*) echo rhel ;;
    *) echo debian ;;
  esac
}

resolve_bin() {
  # Priority: BIN_DIR env → .bin-dir → packaged ../bins → OS-matched release-bins
  local cand="" os
  os="$(canonical_os_bins)"
  if [[ -n "${BIN_DIR:-}" ]]; then
    cand="${BIN_DIR}"
  elif [[ -f "${ROOT}/.bin-dir" ]]; then
    cand="$(cat "${ROOT}/.bin-dir")"
  elif [[ -d "${PKG}/bins" ]]; then
    cand="${PKG}/bins"
  elif [[ -x "${ROOT}/../../release-bins/12.5.1.31-rich-logs/${os}/rtpengine" ]]; then
    cand="${ROOT}/../../release-bins/12.5.1.31-rich-logs/${os}"
  else
    die "no bins found; set BIN_DIR= to release-bins/12.5.1.31-rich-logs/{debian|rhel}"
  fi
  [[ -d "$cand" ]] || die "bins dir missing: $cand (set BIN_DIR=...)"
  BIN="$(cd "$cand" && pwd)"
}

assert_prod() {
  systemctl is-active --quiet "$PROD_D" 2>/dev/null && echo "OK prod $PROD_D active" || echo "NOTE: prod $PROD_D not active"
  systemctl is-active --quiet "$PROD_R" 2>/dev/null && echo "OK prod $PROD_R active" || true
}

check_bins() {
  resolve_bin
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

wait_active() {
  local u="$1" i
  for i in $(seq 1 15); do
    if systemctl is-active --quiet "$u"; then
      echo "active $u"
      return 0
    fi
    # failed / activating-then-fail
    local st
    st=$(systemctl is-active "$u" 2>/dev/null || true)
    if [[ "$st" == "failed" || "$st" == "inactive" ]]; then
      # allow a couple of restart cycles during first seconds
      if [[ $i -ge 5 && "$st" == "failed" ]]; then
        break
      fi
    fi
    sleep 1
  done
  echo "ERROR: $u not active (state=$(systemctl is-active "$u" 2>/dev/null || echo unknown))" >&2
  systemctl status "$u" --no-pager -l 2>&1 | head -40 >&2 || true
  journalctl -u "$u" --since "2 min ago" --no-pager 2>&1 | tail -40 >&2 || true
  return 1
}

cmd_start() {
  need_root start
  systemctl cat "$TEST_D" >/dev/null 2>&1 || die "run: sudo $0 install-units"
  prep
  systemctl reset-failed "$TEST_D" "$TEST_R" 2>/dev/null || true
  systemctl start "$TEST_R"
  wait_active "$TEST_R" || die "rtpengine-recording-test failed — fix bins/libs/config then re-run start"
  systemctl start "$TEST_D"
  wait_active "$TEST_D" || die "rtpengine-test failed — fix bins/libs/ports then re-run start"
  systemctl is-active "$TEST_D" "$TEST_R"
  # show what is listening
  ss -tulnp 2>/dev/null | grep -E '23222|18080|19900|13222' || true
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
  if ! systemctl is-active --quiet "$TEST_D" || ! systemctl is-active --quiet "$TEST_R"; then
    echo "ERROR: test units not both active:" >&2
    systemctl is-active "$TEST_D" "$TEST_R" 2>&1 || true
    systemctl status "$TEST_D" "$TEST_R" --no-pager -l 2>&1 | head -50 >&2 || true
    journalctl -u "$TEST_D" -u "$TEST_R" --since "3 min ago" --no-pager 2>&1 | tail -50 >&2 || true
    die "start test first (sudo $0 start) — see status/logs above"
  fi
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
  echo "==> stop test units (prod untouched)"
  systemctl stop "$TEST_D" "$TEST_R" 2>/dev/null || true
  systemctl disable --now "$TEST_D" "$TEST_R" 2>/dev/null || true
  systemctl reset-failed "$TEST_D" "$TEST_R" 2>/dev/null || true
  # kill leftover test PIDs if any (never pkill -x rtpengine — that would hit prod)
  pkill -f '/rtpengine-test-12.5.pid' 2>/dev/null || true
  pkill -f 'listen-ng=127.0.0.1:23222' 2>/dev/null || true
  pkill -f 'rtpengine-recording-test.ini' 2>/dev/null || true
  sleep 1
  echo "==> remove unit files"
  rm -f "${UNIT_DIR}/${TEST_D}" "${UNIT_DIR}/${TEST_R}"
  rm -f "${UNIT_DIR}/${TEST_D}.d"/* 2>/dev/null || true
  rmdir "${UNIT_DIR}/${TEST_D}.d" 2>/dev/null || true
  rm -f "${UNIT_DIR}/${TEST_R}.d"/* 2>/dev/null || true
  rmdir "${UNIT_DIR}/${TEST_R}.d" 2>/dev/null || true
  # drop per-install bin pointer (optional local state)
  rm -f "${ROOT}/.bin-dir"
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  echo "==> verify unit files gone"
  if [[ -e "${UNIT_DIR}/${TEST_D}" || -e "${UNIT_DIR}/${TEST_R}" ]]; then
    die "unit files still present under ${UNIT_DIR}"
  fi
  if systemctl cat "$TEST_D" >/dev/null 2>&1 || systemctl cat "$TEST_R" >/dev/null 2>&1; then
    echo "WARN: systemd still loads a unit definition; daemon-reload again" >&2
    systemctl daemon-reload
  fi
  # is-active on missing units often prints inactive — show list-unit-files instead
  echo "remaining test unit-files (should be empty):"
  systemctl list-unit-files 'rtpengine-test*' 'rtpengine-recording-test*' --no-pager 2>/dev/null || true
  ls /etc/systemd/system/rtpengine-test* /etc/systemd/system/rtpengine-recording-test* 2>/dev/null && \
    die "test unit paths still on disk" || echo "(none on disk — OK)"
  # do not delete table 44 from kernel by default (harmless); optional:
  # echo "del ${TABLE}" > /proc/rtpengine/control 2>/dev/null || true
  echo "Removed test units only."; assert_prod
  systemctl is-active "$PROD_D" "$PROD_R"
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
