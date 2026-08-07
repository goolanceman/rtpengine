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

# Collect every plausible install path for a binary name (PATH + systemd ExecStart + common dirs)
collect_bin_paths() {
  local name="$1"
  local -a out=()
  local p u exe
  # PATH hits
  while read -r p; do
    [[ -n "$p" && -e "$p" ]] && out+=("$p")
  done < <(type -aP "$name" 2>/dev/null || true)
  # common locations
  for p in     "/usr/bin/$name" "/usr/sbin/$name" "/bin/$name" "/sbin/$name"     "/usr/local/bin/$name" "/usr/local/sbin/$name"
  do
    [[ -e "$p" ]] && out+=("$p")
  done
  # systemd unit ExecStart (running or installed)
  for u in rtpengine.service rtpengine-recording.service            ngcp-rtpengine-daemon.service ngcp-rtpengine-recording-daemon.service; do
    exe=$(systemctl show -p ExecStart --value "$u" 2>/dev/null || true)
    # ExecStart={ path=/usr/bin/foo ; ...
    if [[ "$exe" =~ path=([^ ;]+) ]]; then
      p="${BASH_REMATCH[1]}"
      # exact basename only (avoid rtpengine matching rtpengine-recording)
      [[ "$(basename "$p")" == "$name" && -e "$p" ]] && out+=("$p")
    fi
    # plain ExecStart=/path/foo ...
    for p in $exe; do
      case "$p" in
        /*)
          bn=$(basename "$p")
          [[ "$bn" == "$name" && -e "$p" ]] && out+=("$p")
          ;;
      esac
    done
  done
  # running process
  if pgrep -x "$name" >/dev/null 2>&1; then
    p=$(tr '\0' ' ' <"/proc/$(pgrep -x "$name" | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
    [[ -n "${p:-}" && -e "$p" ]] && out+=("$p")
  fi
  # unique preserve order
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

resolve_prod_paths() {
  DAEMON_PATHS=()
  REC_PATHS=()
  mapfile -t DAEMON_PATHS < <(collect_bin_paths rtpengine)
  mapfile -t REC_PATHS < <(collect_bin_paths rtpengine-recording)
  # primary path = running process preferred, else first found
  DAEMON_PATH=""
  REC_PATH=""
  if pgrep -x rtpengine >/dev/null 2>&1; then
    DAEMON_PATH=$(tr '\0' ' ' <"/proc/$(pgrep -x rtpengine | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
  fi
  if pgrep -x rtpengine-recording >/dev/null 2>&1; then
    REC_PATH=$(tr '\0' ' ' <"/proc/$(pgrep -x rtpengine-recording | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
  fi
  [[ -n "$DAEMON_PATH" && -e "$DAEMON_PATH" ]] || DAEMON_PATH="${DAEMON_PATHS[0]:-/usr/bin/rtpengine}"
  [[ -n "$REC_PATH" && -e "$REC_PATH" ]] || REC_PATH="${REC_PATHS[0]:-/usr/bin/rtpengine-recording}"
  # ensure primary is in the lists
  local p found
  found=0; for p in "${DAEMON_PATHS[@]:-}"; do [[ "$p" == "$DAEMON_PATH" ]] && found=1; done
  [[ $found -eq 0 && -n "$DAEMON_PATH" ]] && DAEMON_PATHS=("$DAEMON_PATH" "${DAEMON_PATHS[@]:-}")
  found=0; for p in "${REC_PATHS[@]:-}"; do [[ "$p" == "$REC_PATH" ]] && found=1; done
  [[ $found -eq 0 && -n "$REC_PATH" ]] && REC_PATHS=("$REC_PATH" "${REC_PATHS[@]:-}")
  # de-dup again
  mapfile -t DAEMON_PATHS < <(printf '%s\n' "${DAEMON_PATHS[@]:-}" | awk 'NF && !seen[$0]++')
  mapfile -t REC_PATHS < <(printf '%s\n' "${REC_PATHS[@]:-}" | awk 'NF && !seen[$0]++')
}

verify_rich_marker() {
  local path="$1" marker="$2" label="$3"
  if [[ ! -e "$path" ]]; then
    echo "WARN: $label missing at $path" >&2
    return 1
  fi
  if grep -ao "$marker" "$path" >/dev/null 2>&1; then
    echo "OK $label has $marker @ $path"
    return 0
  fi
  echo "FAIL $label missing marker '$marker' @ $path" >&2
  return 1
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
  # backup every discovered path (name includes basename-hash of path for multiples)
  local p bn
  i=0
  for p in "${DAEMON_PATHS[@]:-$DAEMON_PATH}"; do
    bn="rtpengine"
    [[ $i -gt 0 ]] && bn="rtpengine.$(echo "$p" | tr '/' '_')"
    backup_one "$p" "$bn"
    i=$((i+1))
  done
  i=0
  for p in "${REC_PATHS[@]:-$REC_PATH}"; do
    bn="rtpengine-recording"
    [[ $i -gt 0 ]] && bn="rtpengine-recording.$(echo "$p" | tr '/' '_')"
    backup_one "$p" "$bn"
    i=$((i+1))
  done
  # also keep primary names always
  [[ -e "$DAEMON_PATH" ]] && cp -a "$DAEMON_PATH" "${BAK_DIR}/rtpengine" || true
  [[ -e "$REC_PATH" ]] && cp -a "$REC_PATH" "${BAK_DIR}/rtpengine-recording" || true
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
  echo "=== bin paths (primary) ==="
  echo "daemon:    $DAEMON_PATH"
  echo "recording: $REC_PATH"
  ls -la "$DAEMON_PATH" "$REC_PATH" 2>/dev/null || true
  echo "=== all discovered daemon paths ==="
  printf '  %s\n' "${DAEMON_PATHS[@]:-}"
  echo "=== all discovered recording paths ==="
  printf '  %s\n' "${REC_PATHS[@]:-}"
  echo "=== systemd ExecStart ==="
  systemctl show -p ExecStart --value rtpengine 2>/dev/null | head -c 300; echo
  systemctl show -p ExecStart --value rtpengine-recording 2>/dev/null | head -c 300; echo
  echo "=== rich-log markers on primary + running paths ==="
  local p
  for p in "${DAEMON_PATHS[@]:-$DAEMON_PATH}"; do
    if grep -ao 'recording DETECT' "$p" >/dev/null 2>&1; then echo "OK DETECT @ $p"; else echo "MISSING DETECT @ $p"; fi
  done
  for p in "${REC_PATHS[@]:-$REC_PATH}"; do
    if grep -ao 'recording NEW' "$p" >/dev/null 2>&1; then echo "OK NEW @ $p"; else echo "MISSING NEW @ $p"; fi
    if grep -ao 'status=SAVED' "$p" >/dev/null 2>&1; then echo "OK SAVED @ $p"; else echo "MISSING SAVED @ $p"; fi
  done
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

  echo "==> install userspace to ALL target paths (force standard locations)"
  # Always overwrite Debian/system paths — discovery alone was missing ExecStart targets
  for p in /usr/bin/rtpengine /usr/local/bin/rtpengine "$DAEMON_PATH"; do
    [[ -n "${p:-}" ]] && DAEMON_PATHS+=("$p")
  done
  for p in /usr/bin/rtpengine-recording /usr/sbin/rtpengine-recording \
           /bin/rtpengine-recording /usr/local/bin/rtpengine-recording "$REC_PATH"; do
    [[ -n "${p:-}" ]] && REC_PATHS+=("$p")
  done
  mapfile -t DAEMON_PATHS < <(printf '%s\n' "${DAEMON_PATHS[@]:-}" | awk 'NF && !seen[$0]++')
  mapfile -t REC_PATHS < <(printf '%s\n' "${REC_PATHS[@]:-}" | awk 'NF && !seen[$0]++')

  echo "    daemon paths:    ${DAEMON_PATHS[*]}"
  echo "    recording paths: ${REC_PATHS[*]}"

  install_one() {
    local src="$1" dest="$2" label="$3"
    [[ -d "$(dirname "$dest")" ]] || { echo "  skip $dest (no parent dir)"; return 0; }
    echo "  install $label -> $dest"
    install -m 755 "$src" "$dest"
    local s1 s2
    s1=$(sha256sum "$src" | awk '{print $1}')
    s2=$(sha256sum "$dest" | awk '{print $1}')
    echo "    sha src=$s1"
    echo "    sha dst=$s2"
    [[ "$s1" == "$s2" ]] || die "hash mismatch installing $label to $dest"
  }

  for p in "${DAEMON_PATHS[@]}"; do
    install_one "${BIN_DIR}/rtpengine" "$p" rtpengine
  done
  for p in "${REC_PATHS[@]}"; do
    install_one "${BIN_DIR}/rtpengine-recording" "$p" rtpengine-recording
  done

  file /usr/bin/rtpengine /usr/bin/rtpengine-recording 2>/dev/null || true
  # hard requirements for siprec unit: /usr/bin/rtpengine-recording MUST be rich-log
  verify_rich_marker /usr/bin/rtpengine-recording 'recording NEW' 'usr-bin-recording' \
    || die "FAILED: /usr/bin/rtpengine-recording still lacks rich logs — refuse to continue"
  verify_rich_marker /usr/bin/rtpengine-recording 'status=SAVED' 'usr-bin-recording' \
    || die "FAILED: /usr/bin/rtpengine-recording missing status=SAVED"
  # daemon if present
  [[ -e /usr/bin/rtpengine ]] && verify_rich_marker /usr/bin/rtpengine 'recording DETECT' 'usr-bin-daemon' || true
  [[ -e /usr/local/bin/rtpengine ]] && verify_rich_marker /usr/local/bin/rtpengine 'recording DETECT' 'local-bin-daemon' || true

  echo "==> kernel module (unchanged — expect xt_RTPENGINE 12.5)"
  lsmod | grep -iE 'rtp|RTP' || echo "WARN: no rtp module loaded yet"
  if [[ ! -e /proc/rtpengine/control ]]; then
    echo "==> loading existing package module xt_RTPENGINE"
    modprobe xt_RTPENGINE 2>/dev/null || true
  fi
  ls -la /proc/rtpengine/control || die "/proc/rtpengine/control missing — load 12.5 kernel package first"

  start_prod
  ls /proc/rtpengine/ || true

  echo "==> verify RUNNING processes load rich-log bins"
  sleep 1
  local rp rr
  rp=$(tr '\0' ' ' <"/proc/$(pgrep -x rtpengine | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
  rr=$(tr '\0' ' ' <"/proc/$(pgrep -x rtpengine-recording | head -1)/cmdline" 2>/dev/null | awk '{print $1}')
  echo "  running daemon:    ${rp:-none}"
  echo "  running recording: ${rr:-none}"
  [[ -n "${rp:-}" ]] && verify_rich_marker "$rp" 'recording DETECT' 'running-daemon'
  [[ -n "${rr:-}" ]] && verify_rich_marker "$rr" 'recording NEW' 'running-recording'
  [[ -n "${rr:-}" ]] && verify_rich_marker "$rr" 'status=SAVED' 'running-recording'
  if [[ -n "${rr:-}" ]] && command -v sha256sum >/dev/null; then
    s1=$(sha256sum "${BIN_DIR}/rtpengine-recording" | awk '{print $1}')
    s2=$(sha256sum "$rr" | awk '{print $1}')
    echo "  recording src sha=$s1"
    echo "  recording run sha=$s2 path=$rr"
    [[ "$s1" == "$s2" ]] || die "RUNNING rtpengine-recording is NOT the promoted binary (still old?). path=$rr"
  fi
  if [[ -n "${rp:-}" ]] && command -v sha256sum >/dev/null; then
    s1=$(sha256sum "${BIN_DIR}/rtpengine" | awk '{print $1}')
    s2=$(sha256sum "$rp" | awk '{print $1}')
    echo "  daemon src sha=$s1"
    echo "  daemon run sha=$s2 path=$rp"
    [[ "$s1" == "$s2" ]] || die "RUNNING rtpengine is NOT the promoted binary. path=$rp"
  fi

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
