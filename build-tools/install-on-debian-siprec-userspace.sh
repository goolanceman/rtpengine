#!/bin/bash
# 12.5.1.31 rich-log USERSPACE promote/rollback for Debian siprec.
# Kernel module is never installed/replaced.
#
# Usage:
#   sudo bash build-tools/install-on-debian-siprec-userspace.sh <command>
#   BIN_DIR=... sudo -E bash ... promote
#
# Commands:
#   help | status | list-backups | backup | promote | rollback [TS|latest]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${ROOT}/.." && pwd)"
BAK_ROOT="/var/backups/rtpengine-rich-logs"
CMD="${1:-help}"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ $(id -u) -eq 0 ]] || die "run as root: sudo $0 $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

usage() {
  cat <<EOF
Usage: sudo $0 <command> [args]

Commands:
  help              This help
  status            Show prod services, bin paths, rich-log markers, backups
  list-backups      List /var/backups/rtpengine-rich-logs/*
  backup            Backup current prod bins/configs only (no stop/replace)
  promote           Backup + stop prod + install rich-log bins + start
  rollback [id]     Restore bins from backup (id = timestamp dir or 'latest')

Bins resolution for promote (first match):
  1) BIN_DIR=... env
  2) $ROOT/bins
  3) $REPO/release-bins/12.5.1.31-rich-logs/debian
  4) $REPO/debian-bins/bins

Examples:
  sudo $0 status
  BIN_DIR=\$PWD/release-bins/12.5.1.31-rich-logs/debian sudo -E $0 promote
  sudo $0 list-backups
  sudo $0 rollback latest
  sudo $0 rollback 20260807123000
EOF
}

resolve_prod_paths() {
  DAEMON_PATH="$(command -v rtpengine || true)"
  REC_PATH="$(command -v rtpengine-recording || true)"
  [[ -n "$DAEMON_PATH" ]] || DAEMON_PATH=/usr/bin/rtpengine
  [[ -n "$REC_PATH" ]] || REC_PATH=/usr/bin/rtpengine-recording
  [[ -x /usr/sbin/rtpengine-recording ]] && REC_PATH=/usr/sbin/rtpengine-recording
  # prefer path used by running service if present
  if pgrep -x rtpengine >/dev/null 2>&1; then
    local rp
    rp=$(tr '\0' ' ' <"/proc/$(pgrep -x rtpengine | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
    [[ -x "${rp:-}" ]] && DAEMON_PATH="$rp"
  fi
  if pgrep -x rtpengine-recording >/dev/null 2>&1; then
    local rr
    rr=$(tr '\0' ' ' <"/proc/$(pgrep -x rtpengine-recording | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
    [[ -x "${rr:-}" ]] && REC_PATH="$rr"
  fi
}

resolve_bin_dir() {
  if [[ -n "${BIN_DIR:-}" ]]; then
    BIN_DIR="$(cd "${BIN_DIR}" && pwd)"
  elif [[ -x "${ROOT}/bins/rtpengine" ]]; then
    BIN_DIR="${ROOT}/bins"
  elif [[ -x "${REPO}/release-bins/12.5.1.31-rich-logs/debian/rtpengine" ]]; then
    BIN_DIR="${REPO}/release-bins/12.5.1.31-rich-logs/debian"
  elif [[ -x "${REPO}/debian-bins/bins/rtpengine" ]]; then
    BIN_DIR="${REPO}/debian-bins/bins"
  else
    die "no binaries found. Set BIN_DIR= to debian rtpengine dir."
  fi
  [[ -x "${BIN_DIR}/rtpengine" ]] || die "missing ${BIN_DIR}/rtpengine"
  [[ -x "${BIN_DIR}/rtpengine-recording" ]] || die "missing ${BIN_DIR}/rtpengine-recording"
}

stop_prod() {
  echo "==> stopping production services"
  systemctl stop rtpengine rtpengine-recording 2>/dev/null || true
  sleep 1
  pkill -x rtpengine 2>/dev/null || true
  pkill -x rtpengine-recording 2>/dev/null || true
  sleep 1
}

start_prod() {
  echo "==> starting production services"
  systemctl start rtpengine-recording
  sleep 1
  systemctl start rtpengine
  sleep 2
  systemctl is-active rtpengine rtpengine-recording
}

do_backup() {
  # uses global DAEMON_PATH REC_PATH; sets BAK_DIR TS
  need_root backup
  need systemctl
  resolve_prod_paths
  TS=$(date +%Y%m%d%H%M%S)
  BAK_DIR="${BAK_ROOT}/${TS}"
  mkdir -p "${BAK_DIR}"

  echo "==> backup BEFORE change -> ${BAK_DIR}"
  backup_one() {
    local src="$1" name="$2"
    if [[ -e "$src" ]]; then
      cp -a "$src" "${BAK_DIR}/${name}"
      cp -a "$src" "${src}.bak.${TS}"
      ls -la "${BAK_DIR}/${name}" "${src}.bak.${TS}"
    else
      echo "NOTE: no existing $name at $src"
    fi
  }
  backup_one "$DAEMON_PATH" rtpengine
  backup_one "$REC_PATH" rtpengine-recording
  for f in \
    /etc/systemd/system/rtpengine.service \
    /etc/systemd/system/rtpengine-recording.service \
    /lib/systemd/system/rtpengine.service \
    /lib/systemd/system/rtpengine-recording.service \
    /usr/local/libexec/rtpengine-start.sh \
    /etc/rtpengine.conf \
    /etc/rtpengine-recording.ini
  do
    [[ -e "$f" ]] && cp -a "$f" "${BAK_DIR}/$(basename "$f")" || true
  done
  {
    echo "TS=${TS}"
    echo "DAEMON_PATH=${DAEMON_PATH}"
    echo "REC_PATH=${REC_PATH}"
    echo "HOST=$(hostname -f 2>/dev/null || hostname)"
    echo "KERNEL=$(uname -r)"
    echo "WHEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    command -v sha256sum >/dev/null 2>&1 && {
      [[ -e "$DAEMON_PATH" ]] && sha256sum "$DAEMON_PATH" || true
      [[ -e "$REC_PATH" ]] && sha256sum "$REC_PATH" || true
    }
  } > "${BAK_DIR}/META.txt"
  echo "${DAEMON_PATH}" > "${BAK_DIR}/DAEMON_PATH.txt"
  echo "${REC_PATH}" > "${BAK_DIR}/REC_PATH.txt"
  # pointer to latest backup for easy rollback
  ln -sfn "${TS}" "${BAK_ROOT}/latest"
  echo "Backup dir: ${BAK_DIR}"
  ls -la "${BAK_DIR}"
  echo "${TS}"
}

latest_backup_ts() {
  if [[ -L "${BAK_ROOT}/latest" ]]; then
    readlink "${BAK_ROOT}/latest"
    return
  fi
  ls -1 "${BAK_ROOT}" 2>/dev/null | grep -E '^[0-9]{14}$' | sort | tail -1
}

resolve_backup() {
  local id="${1:-latest}"
  local ts="" dir=""
  if [[ "$id" == "latest" ]]; then
    ts="$(latest_backup_ts)"
    [[ -n "$ts" ]] || die "no backups under ${BAK_ROOT}"
  elif [[ "$id" =~ ^[0-9]{14}$ ]]; then
    ts="$id"
  elif [[ -d "$id" ]]; then
    dir="$(cd "$id" && pwd)"
    ts="$(basename "$dir")"
  else
    die "unknown backup id: $id (use latest or YYYYMMDDHHMMSS)"
  fi
  BAK_DIR="${dir:-${BAK_ROOT}/${ts}}"
  [[ -d "$BAK_DIR" ]] || die "backup not found: $BAK_DIR"
  TS="$ts"
  if [[ -f "${BAK_DIR}/DAEMON_PATH.txt" ]]; then
    DAEMON_PATH="$(cat "${BAK_DIR}/DAEMON_PATH.txt")"
  fi
  if [[ -f "${BAK_DIR}/REC_PATH.txt" ]]; then
    REC_PATH="$(cat "${BAK_DIR}/REC_PATH.txt")"
  fi
  resolve_prod_paths
  # prefer paths recorded at backup time when files still make sense
  [[ -f "${BAK_DIR}/DAEMON_PATH.txt" ]] && DAEMON_PATH="$(cat "${BAK_DIR}/DAEMON_PATH.txt")"
  [[ -f "${BAK_DIR}/REC_PATH.txt" ]] && REC_PATH="$(cat "${BAK_DIR}/REC_PATH.txt")"
  [[ -f "${BAK_DIR}/rtpengine" ]] || die "backup missing rtpengine binary: ${BAK_DIR}/rtpengine"
  [[ -f "${BAK_DIR}/rtpengine-recording" ]] || die "backup missing rtpengine-recording: ${BAK_DIR}/rtpengine-recording"
}

cmd_status() {
  resolve_prod_paths
  echo "=== production services ==="
  systemctl is-active rtpengine 2>/dev/null || echo inactive
  systemctl is-active rtpengine-recording 2>/dev/null || echo inactive
  echo "=== bin paths ==="
  echo "daemon:    $DAEMON_PATH"
  echo "recording: $REC_PATH"
  ls -la "$DAEMON_PATH" "$REC_PATH" 2>/dev/null || true
  echo "=== rich-log markers ==="
  if [[ -x "$DAEMON_PATH" ]]; then
    grep -ao 'recording DETECT' "$DAEMON_PATH" 2>/dev/null | head -1 && echo "(DETECT present)" || echo "DETECT: missing"
    grep -ao 'recording START' "$DAEMON_PATH" 2>/dev/null | head -1 >/dev/null && echo "START: present" || echo "START: missing"
  fi
  if [[ -x "$REC_PATH" ]]; then
    grep -ao 'status=SAVED' "$REC_PATH" 2>/dev/null | head -1 >/dev/null && echo "SAVED: present" || echo "SAVED: missing"
  fi
  echo "=== kernel ==="
  lsmod | grep -iE 'rtp|RTP' || echo "(no rtp module)"
  ls -la /proc/rtpengine/ 2>/dev/null || true
  echo "=== running cmds ==="
  ps -o pid,args= -C rtpengine,rtpengine-recording 2>/dev/null || true
  echo "=== backups ==="
  if [[ -d "$BAK_ROOT" ]]; then
    ls -1 "$BAK_ROOT" | grep -E '^[0-9]{14}$' | sort | tail -10 || true
    [[ -L "${BAK_ROOT}/latest" ]] && echo "latest -> $(readlink "${BAK_ROOT}/latest")"
  else
    echo "(none yet under $BAK_ROOT)"
  fi
}

cmd_list_backups() {
  if [[ ! -d "$BAK_ROOT" ]]; then
    echo "(no $BAK_ROOT)"
    return 0
  fi
  local ts
  for ts in $(ls -1 "$BAK_ROOT" | grep -E '^[0-9]{14}$' | sort); do
    echo "---- $ts ----"
    ls -la "${BAK_ROOT}/${ts}" 2>/dev/null | sed 's/^/  /'
    [[ -f "${BAK_ROOT}/${ts}/META.txt" ]] && sed 's/^/  /' "${BAK_ROOT}/${ts}/META.txt"
  done
  [[ -L "${BAK_ROOT}/latest" ]] && echo "latest -> $(readlink "${BAK_ROOT}/latest")"
}

cmd_backup() {
  need_root backup
  do_backup >/dev/null
  echo "OK backup ${BAK_DIR}"
  cmd_list_backups | tail -20
}

cmd_promote() {
  need_root promote
  need systemctl
  need install
  resolve_bin_dir
  resolve_prod_paths

  echo "==> script: $ROOT"
  echo "==> bins:   $BIN_DIR"
  echo "==> version: $(cat "${BIN_DIR}/../VERSION" 2>/dev/null || echo unknown) sha=$(cat "${BIN_DIR}/../GIT_SHA" 2>/dev/null || echo unknown)"
  echo "==> host kernel: $(uname -r)"
  echo "==> USERSPACE ONLY — kernel module not touched"
  echo "==> TARGET daemon=$DAEMON_PATH recording=$REC_PATH"
  echo "==> THIS STOPS AND REPLACES PRODUCTION rtpengine + rtpengine-recording"

  do_backup

  stop_prod

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
  ls -la /proc/rtpengine/control || die "/proc/rtpengine/control missing — load 12.5 kernel package first"

  start_prod
  ls /proc/rtpengine/ || true

  echo
  echo "PROMOTE DONE. Watch logs:"
  echo "  journalctl -u rtpengine -u rtpengine-recording -f | grep recording"
  echo "Rollback:"
  echo "  sudo $0 rollback latest"
  echo "  # or: sudo $0 rollback ${TS}"
  echo "Backup: ${BAK_DIR}"
}

cmd_rollback() {
  need_root rollback
  need systemctl
  need install
  local id="${1:-latest}"
  resolve_backup "$id"
  echo "==> rollback from ${BAK_DIR}"
  echo "==> restore daemon -> ${DAEMON_PATH}"
  echo "==> restore recording -> ${REC_PATH}"

  # safety backup of whatever is currently installed before rollback
  echo "==> safety backup of current bins before rollback"
  local safety_ts safety_dir
  safety_ts=$(date +%Y%m%d%H%M%S)
  safety_dir="${BAK_ROOT}/pre-rollback-${safety_ts}"
  mkdir -p "$safety_dir"
  [[ -e "$DAEMON_PATH" ]] && cp -a "$DAEMON_PATH" "${safety_dir}/rtpengine" || true
  [[ -e "$REC_PATH" ]] && cp -a "$REC_PATH" "${safety_dir}/rtpengine-recording" || true
  echo "${DAEMON_PATH}" > "${safety_dir}/DAEMON_PATH.txt"
  echo "${REC_PATH}" > "${safety_dir}/REC_PATH.txt"
  echo "Safety backup: ${safety_dir}"

  stop_prod

  install -m 755 "${BAK_DIR}/rtpengine" "$DAEMON_PATH"
  install -m 755 "${BAK_DIR}/rtpengine-recording" "$REC_PATH"
  file "$DAEMON_PATH" "$REC_PATH"

  start_prod
  ls /proc/rtpengine/ || true

  echo
  echo "ROLLBACK DONE from ${TS}"
  echo "  daemon:    $DAEMON_PATH"
  echo "  recording: $REC_PATH"
  echo "If wrong backup, retry: sudo $0 rollback <other-TS>"
  echo "Current pre-rollback copy: ${safety_dir}"
}

case "$CMD" in
  help|-h|--help) usage ;;
  status) cmd_status ;;
  list-backups) cmd_list_backups ;;
  backup) cmd_backup ;;
  promote|install) cmd_promote ;;
  rollback|restore)
    shift || true
    cmd_rollback "${1:-latest}"
    ;;
  *)
    usage >&2
    die "unknown command: $CMD"
    ;;
esac
