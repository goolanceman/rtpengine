#!/usr/bin/env bash
# Assemble rtpengine-12.5.1.31-rich-logs-<UTC datetime>.tar.gz from the
# canonical bin dirs. Filename includes the source commit and UTC timestamp.
#   Debian: build-tools/bins/debian/
#   RHEL:   build-tools/bins/rhel/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REL="${ROOT}/release-bins/12.5.1.31-rich-logs"
BIN_ROOT="${ROOT}/build-tools/bins"
TAR_DIR="${ROOT}/build-tools/tars"
DEB="${BIN_ROOT}/debian"
RHEL="${BIN_ROOT}/rhel"
NAME="rtpengine-12.5.1.31-rich-logs"
MARKER_REUSE='Re-using mix input index #%u'
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
OUT="$(stamp_out "${OUT:-${TAR_DIR}/${NAME}-${SHA}.tar.gz}")"
mkdir -p "$(dirname "${OUT}")"

die() { echo "ERROR: $*" >&2; exit 1; }

need_bins() {
  local d="$1" label="$2"
  [[ -x "${d}/rtpengine" ]] || die "missing ${d}/rtpengine (${label})"
  [[ -x "${d}/rtpengine-recording" ]] || die "missing ${d}/rtpengine-recording (${label})"
  grep -aFq "${MARKER_REUSE}" "${d}/rtpengine-recording" \
    || die "${label} recording bin missing mixer marker"
}

need_bins "${DEB}" debian
need_bins "${RHEL}" rhel

mkdir -p "${REL}"
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
printf 'Debian bins from build-tools/bins/debian\n' \
  > "${PKG}/bins/README.txt"
install -m 0755 "${SCRIPT_DIR}/install-on-debian-siprec-userspace.sh" \
  "${PKG}/install-on-debian-siprec.sh"
cp -a "${SCRIPT_DIR}/side-by-side-test" "${PKG}/side-by-side-test"
rm -f "${PKG}/side-by-side-test/.bin-dir"
printf '%s\n' "${SHA}" > "${PKG}/GIT_SHA"
printf '%s\n' "${BRANCH}" > "${PKG}/GIT_BRANCH"
printf '%s\n' "12.5.1.31" > "${PKG}/VERSION"
printf 'See build-tools/BINS.md — bins live in build-tools/bins/debian\n' > "${PKG}/README.md"
tar -C "${INNER}" -czf "${INNER}/debian-bins-package.tar.gz" debian-bins

echo "==> stage deploy tarball"
STAGE="$(mktemp -d)"
trap 'rm -rf "${INNER}" "${STAGE}"' EXIT
BASE="${STAGE}/${NAME}"
mkdir -p "${BASE}/release-bins" "${BASE}/build-tools"
cp -a "${REL}" "${BASE}/release-bins/"
install -m 0644 "${INNER}/debian-bins-package.tar.gz" \
  "${BASE}/release-bins/12.5.1.31-rich-logs/debian-bins-package.tar.gz"
for p in debian rhel; do
  mkdir -p "${BASE}/release-bins/12.5.1.31-rich-logs/${p}"
  install -m 0755 "${BIN_ROOT}/${p}/rtpengine" \
    "${BASE}/release-bins/12.5.1.31-rich-logs/${p}/rtpengine"
  install -m 0755 "${BIN_ROOT}/${p}/rtpengine-recording" \
    "${BASE}/release-bins/12.5.1.31-rich-logs/${p}/rtpengine-recording"
done
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

Canonical build outputs:
  Debian: build-tools/bins/debian/
  RHEL:   build-tools/bins/rhel/

Recording fix (${SHA}): ignore RTPengine's synthetic NAT-piercing probe (PT 127,
sequence 65535, SSRC 0) instead of passing it to the audio decoder.

Promote on Debian siprec:
  BIN_DIR="\$PWD/build-tools/bins/debian" \\
    sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote

Promote on RHEL lab:
  BIN_DIR="\$PWD/build-tools/bins/rhel" \\
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
  grep -aFq "${MARKER_REUSE}" "${tmp}" || { rm -f "${tmp}"; die "${p} packaged recording missing mixer marker"; }
  rm -f "${tmp}"
  echo "OK mixer marker"
  sha256sum "${BIN_ROOT}/${p}/rtpengine-recording"
done
echo "OK ${OUT} sha=${SHA} built_at=${BUILT_AT}"
