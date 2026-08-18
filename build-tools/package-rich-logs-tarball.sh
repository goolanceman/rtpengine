#!/usr/bin/env bash
# Assemble rtpengine-12.5.1.31-rich-logs-<UTC datetime>.tar.gz from the
# canonical bin dirs. Filename always ends with YYYYMMDDHHMMSS.
#   Debian: release-bins/12.5.1.31-rich-logs/debian/
#   RHEL:   release-bins/12.5.1.31-rich-logs/rhel/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REL="${ROOT}/release-bins/12.5.1.31-rich-logs"
DEB="${REL}/debian"
RHEL="${REL}/rhel"
NAME="rtpengine-12.5.1.31-rich-logs"
MARKER_REUSE='Re-using mix input index #%u for new SSRC on same stream'
MARKER_IDLE='Not re-using mix input index #%u: previous SSRC still active'
TS="$(date -u +%Y%m%d%H%M%S)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SHA="$(git -C "${ROOT}" rev-parse --short HEAD)"
BRANCH="$(git -C "${ROOT}" rev-parse --abbrev-ref HEAD)"

# Always append UTC datetime before .tar.gz (skip if already stamped).
stamp_out() {
  local path="$1"
  if [[ "${path}" =~ -[0-9]{14}\.tar\.gz$ ]]; then
    printf '%s\n' "${path}"
    return
  fi
  if [[ "${path}" == *.tar.gz ]]; then
    printf '%s\n' "${path%.tar.gz}-${TS}.tar.gz"
    return
  fi
  printf '%s\n' "${path}-${TS}"
}
OUT="$(stamp_out "${OUT:-${ROOT}/${NAME}.tar.gz}")"

die() { echo "ERROR: $*" >&2; exit 1; }

need_bins() {
  local d="$1" label="$2"
  [[ -x "${d}/rtpengine" ]] || die "missing ${d}/rtpengine (${label})"
  [[ -x "${d}/rtpengine-recording" ]] || die "missing ${d}/rtpengine-recording (${label})"
  grep -aFq "${MARKER_REUSE}" "${d}/rtpengine-recording" \
    || die "${label} recording bin missing mixer reuse marker"
  grep -aFq "${MARKER_IDLE}" "${d}/rtpengine-recording" \
    || die "${label} recording bin missing idle-guard marker (rebuild bins first)"
}

need_bins "${DEB}" debian
need_bins "${RHEL}" rhel

echo "==> metadata SHA=${SHA} BRANCH=${BRANCH} BUILT_AT=${BUILT_AT}"
printf '%s\n' "12.5.1.31" > "${REL}/VERSION"
printf '%s\n' "${SHA}" > "${REL}/GIT_SHA"
printf '%s\n' "${BRANCH}" > "${REL}/BRANCH"
printf '%s\n' "${BUILT_AT}" > "${REL}/BUILT_AT"

echo "==> inner debian-bins-package.tar.gz"
INNER="$(mktemp -d)"
trap 'rm -rf "${INNER}"' EXIT
PKG="${INNER}/debian-bins"
mkdir -p "${PKG}/bins"
install -m 0755 "${DEB}/rtpengine" "${PKG}/bins/rtpengine"
install -m 0755 "${DEB}/rtpengine-recording" "${PKG}/bins/rtpengine-recording"
printf 'Canonical Debian bins from release-bins/12.5.1.31-rich-logs/debian\n' \
  > "${PKG}/bins/README.txt"
install -m 0755 "${SCRIPT_DIR}/install-on-debian-siprec-userspace.sh" \
  "${PKG}/install-on-debian-siprec.sh"
cp -a "${SCRIPT_DIR}/side-by-side-test" "${PKG}/side-by-side-test"
rm -f "${PKG}/side-by-side-test/.bin-dir"
printf '%s\n' "${SHA}" > "${PKG}/GIT_SHA"
printf '%s\n' "${BRANCH}" > "${PKG}/GIT_BRANCH"
printf '%s\n' "12.5.1.31" > "${PKG}/VERSION"
printf 'See build-tools/BINS.md — bins live in release-bins/.../debian\n' > "${PKG}/README.md"
tar -C "${INNER}" -czf "${REL}/debian-bins-package.tar.gz" debian-bins

echo "==> stage deploy tarball"
STAGE="$(mktemp -d)"
trap 'rm -rf "${INNER}" "${STAGE}"' EXIT
BASE="${STAGE}/${NAME}"
mkdir -p "${BASE}/release-bins" "${BASE}/build-tools"
cp -a "${REL}" "${BASE}/release-bins/"
# never ship local backups
rm -rf "${BASE}/release-bins/12.5.1.31-rich-logs/"*.bak.* \
       "${BASE}/release-bins/12.5.1.31-rich-logs/"*.bak
cp -a "${SCRIPT_DIR}/side-by-side-test" "${BASE}/build-tools/"
rm -f "${BASE}/build-tools/side-by-side-test/.bin-dir"
install -m 0755 "${SCRIPT_DIR}/install-on-debian-siprec-userspace.sh" \
  "${BASE}/build-tools/install-on-debian-siprec-userspace.sh"
install -m 0755 "${SCRIPT_DIR}/fix-recording-bin-on-siprec.sh" \
  "${BASE}/build-tools/fix-recording-bin-on-siprec.sh"
install -m 0755 "${SCRIPT_DIR}/package-rich-logs-tarball.sh" \
  "${BASE}/build-tools/package-rich-logs-tarball.sh"
cp -a "${SCRIPT_DIR}/CONFLUENCE-12.5.1.31-rich-logs-usage.md" "${BASE}/build-tools/"
cp -a "${SCRIPT_DIR}/BINS.md" "${BASE}/build-tools/"
printf '%s\n' "12.5.1.31" > "${BASE}/VERSION"
printf '%s\n' "${SHA}" > "${BASE}/GIT_SHA"
printf '%s\n' "${BUILT_AT}" > "${BASE}/BUILT_AT"
cat > "${BASE}/README.md" <<EOF
# rtpengine 12.5.1.31 rich recording + call QoS logs

See build-tools/BINS.md and build-tools/CONFLUENCE-12.5.1.31-rich-logs-usage.md

Canonical bins (do not use rhel-binaries/ or debian-bins/):
  Debian: release-bins/12.5.1.31-rich-logs/debian/
  RHEL:   release-bins/12.5.1.31-rich-logs/rhel/

Mixer fix (${SHA}): stream-pin + 1s idle-guard so overlapping SSRCs keep separate slots; MIX_MAX_INPUTS=16.

Promote on Debian siprec:
  BIN_DIR="\$PWD/release-bins/12.5.1.31-rich-logs/debian" \\
    sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote

Promote on RHEL lab:
  BIN_DIR="\$PWD/release-bins/12.5.1.31-rich-logs/rhel" \\
    sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote
EOF

if [[ -f "${OUT}" ]]; then
  cp -a "${OUT}" "${OUT}.bak.${TS}"
  echo "==> backed up previous tarball -> ${OUT}.bak.${TS}"
fi
tar -C "${STAGE}" -czf "${OUT}" "${NAME}"
echo "==> wrote ${OUT}"
ls -lah "${OUT}"
echo
echo "VERIFY"
tar -tzf "${OUT}" | sed -n '1,40p'
for p in debian rhel; do
  echo "-- ${p} recording --"
  tmp="$(mktemp)"
  tar -xOf "${OUT}" "${NAME}/release-bins/12.5.1.31-rich-logs/${p}/rtpengine-recording" > "${tmp}"
  grep -aFq "${MARKER_REUSE}" "${tmp}" || { rm -f "${tmp}"; die "${p} packaged recording missing mixer reuse marker"; }
  grep -aFq "${MARKER_IDLE}" "${tmp}" || { rm -f "${tmp}"; die "${p} packaged recording missing idle-guard marker"; }
  rm -f "${tmp}"
  echo "OK mixer reuse + idle-guard markers"
  sha256sum "${REL}/${p}/rtpengine-recording"
done
echo "OK ${OUT} sha=${SHA} built_at=${BUILT_AT}"
