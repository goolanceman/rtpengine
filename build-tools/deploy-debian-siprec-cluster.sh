#!/usr/bin/env bash
# Build, package, copy, and optionally promote Debian userspace binaries on a
# SIPREC host pair. Promotion is sequential and uses the backup-first installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REL="${ROOT}/release-bins/12.5.1.31-rich-logs"
DEB="${REL}/debian"
VERSION="12.5.1.31"
SSH_USER="${SSH_USER:-}"
REMOTE_BASE="${REMOTE_BASE:-/var/tmp/rtpengine-rich-logs-deploy}"
PROMOTE=0
BUILD=1
ARCHIVE=""
HOSTS=()

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

usage() {
  cat <<EOF
Usage: $0 [options] [host ...]

Defaults:
  SSH user:  SSH config (set SSH_USER=... to override)
  Hosts:     euprod2-frankfurt-siprec-01 euprod2-frankfurt-siprec-02
  Remote dir: ${REMOTE_BASE}

Options:
  --promote              Copy, extract, and promote sequentially
  --no-build             Reuse existing canonical Debian binaries
  --archive PATH         Use/write this tarball path instead of a generated one
  --remote-base PATH     Remote staging root (default: ${REMOTE_BASE})
  -h, --help             Show this help

Examples:
  $0
  $0 --promote euprod2-frankfurt-siprec-01 euprod2-frankfurt-siprec-02
  SSH_USER=deploy $0 --promote siprec01 siprec02
EOF
}

while (($#)); do
  case "$1" in
    --promote) PROMOTE=1; shift ;;
    --no-build) BUILD=0; shift ;;
    --archive) [[ $# -ge 2 ]] || die "--archive needs a path"; ARCHIVE="$2"; shift 2 ;;
    --remote-base) [[ $# -ge 2 ]] || die "--remote-base needs a path"; REMOTE_BASE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

if ((${#HOSTS[@]} == 0)); then
  HOSTS=(euprod2-frankfurt-siprec-01 euprod2-frankfurt-siprec-02)
fi

for tool in docker sha256sum tar scp ssh install; do need "$tool"; done

if ((BUILD)); then
  echo "==> building Debian binaries"
  OUT_DIR="${DEB}" bash "${SCRIPT_DIR}/docker-build-binaries.sh"
fi

[[ -x "${DEB}/rtpengine" ]] || die "missing ${DEB}/rtpengine"
[[ -x "${DEB}/rtpengine-recording" ]] || die "missing ${DEB}/rtpengine-recording"

SHA="$(git -C "${ROOT}" rev-parse --short HEAD)"
TS="$(date -u +%Y%m%d%H%M%S)"
NAME="rtpengine-${VERSION}-debian-${TS}-${SHA}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
PACKAGE_ROOT="${STAGE}/${NAME}"
mkdir -p "${PACKAGE_ROOT}/bins"
install -m 0755 "${DEB}/rtpengine" "${PACKAGE_ROOT}/bins/rtpengine"
install -m 0755 "${DEB}/rtpengine-recording" "${PACKAGE_ROOT}/bins/rtpengine-recording"
install -m 0755 "${SCRIPT_DIR}/install-on-debian-siprec-userspace.sh" \
  "${PACKAGE_ROOT}/install-on-debian-siprec-userspace.sh"
printf '%s\n' "${VERSION}" > "${PACKAGE_ROOT}/VERSION"
printf '%s\n' "${SHA}" > "${PACKAGE_ROOT}/GIT_SHA"
cat > "${PACKAGE_ROOT}/README.md" <<EOF
# rtpengine Debian SIPREC userspace deployment

Version: ${VERSION}
Source commit: ${SHA}

The installer backs up existing binaries and service/config files before
stopping services and replacing userspace binaries. The kernel module is not
installed or replaced.
EOF

if [[ -z "${ARCHIVE}" ]]; then
  ARCHIVE="${ROOT}/${NAME}.tar.gz"
fi
mkdir -p "$(dirname "${ARCHIVE}")"
tar -C "${STAGE}" -czf "${ARCHIVE}" "${NAME}"
ARCHIVE_BASE="$(basename "${ARCHIVE}")"
ARCHIVE_SHA="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
printf '%s  %s\n' "${ARCHIVE_SHA}" "${ARCHIVE_BASE}" > "${ARCHIVE}.sha256"
tar -tzf "${ARCHIVE}" >/dev/null
echo "==> archive: ${ARCHIVE}"
echo "==> sha256:  ${ARCHIVE_SHA}"

if (( ! PROMOTE )); then
  echo "Package created; no hosts changed."
  echo "Run with --promote to copy and promote on: ${HOSTS[*]}"
  exit 0
fi

for host in "${HOSTS[@]}"; do
  if [[ -n "${SSH_USER}" ]]; then
    target="${SSH_USER}@${host}"
  else
    target="${host}"
  fi
  remote_dir="${REMOTE_BASE}/${NAME}"
  echo
  echo "==> preflight ${target}"
  ssh -o ConnectTimeout=15 "${target}" \
    "test -f /etc/debian_version && command -v sudo >/dev/null || { echo 'Debian or sudo preflight failed' >&2; exit 1; }"
  ssh "${target}" "mkdir -p '${REMOTE_BASE}'"
  echo "==> copy ${ARCHIVE_BASE} to ${target}"
  scp "${ARCHIVE}" "${ARCHIVE}.sha256" "${target}:${REMOTE_BASE}/"
  ssh "${target}" "set -eu
    cd '${REMOTE_BASE}'
    sha256sum -c '${ARCHIVE_BASE}.sha256'
    mkdir -p '${remote_dir}'
    tar -xzf '${ARCHIVE_BASE}' -C '${REMOTE_BASE}'
    test -x '${remote_dir}/bins/rtpengine'
    test -x '${remote_dir}/bins/rtpengine-recording'
    sha256sum '${remote_dir}/bins/rtpengine' '${remote_dir}/bins/rtpengine-recording'"
  echo "==> promote ${target}"
  ssh -tt "${target}" \
    "sudo env BIN_DIR='${remote_dir}/bins' bash '${remote_dir}/install-on-debian-siprec-userspace.sh' promote"
  ssh "${target}" \
    "sudo systemctl is-active --quiet rtpengine && sudo systemctl is-active --quiet rtpengine-recording"
  echo "OK promoted ${target}; proceeding to next host"
done

echo
echo "DEPLOYMENT COMPLETE: ${HOSTS[*]}"
echo "Archive: ${ARCHIVE}"
echo "Remote staging: ${REMOTE_BASE}/${NAME}"