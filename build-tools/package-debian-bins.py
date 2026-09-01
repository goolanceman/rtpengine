#!/usr/bin/env python3
"""Assemble optional debian-bins staging package from the canonical Debian dir.

Official bins live in release-bins/12.5.1.31-rich-logs/debian/ (see BINS.md).
This script only copies those bins into a debian-bins/ staging tree.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "debian-bins"
CANONICAL = ROOT / "release-bins" / "12.5.1.31-rich-logs" / "debian"
SHA = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], text=True).strip()


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.check_call(cmd, cwd=ROOT)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "bins").mkdir(exist_ok=True)
    (OUT / "kmod").mkdir(exist_ok=True)
    (OUT / "dkms-src").mkdir(exist_ok=True)

    # Extract kmod image artifacts
    extract = OUT / "_extract"
    if extract.exists():
        shutil.rmtree(extract)
    extract.mkdir()
    cid = subprocess.check_output(
        ["docker", "create", "rtpengine-debian-kmod:local"], text=True
    ).strip()
    try:
        run(["docker", "cp", f"{cid}:/out/.", str(extract) + "/"])
    finally:
        subprocess.call(["docker", "rm", cid], stdout=subprocess.DEVNULL)

    kmod_src = extract / "kmod"
    if kmod_src.exists():
        for p in kmod_src.iterdir():
            dest = OUT / "kmod" / p.name
            if dest.exists():
                shutil.rmtree(dest) if dest.is_dir() else dest.unlink()
            shutil.copytree(p, dest) if p.is_dir() else shutil.copy2(p, dest)

    dkms_src = extract / "dkms-src"
    if dkms_src.exists():
        for p in dkms_src.iterdir():
            dest = OUT / "dkms-src" / p.name
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(p, dest)

    for name in ("VERSION", "UPSTREAM"):
        src = extract / name
        if src.exists():
            shutil.copy2(src, OUT / name)

    shutil.rmtree(extract)

    bins = OUT / "bins"
    for b in ("rtpengine", "rtpengine-recording"):
        src = CANONICAL / b
        if not src.exists():
            raise SystemExit(
                f"missing {src} — put Debian bins in release-bins/12.5.1.31-rich-logs/debian/ "
                "(see build-tools/BINS.md)"
            )
        shutil.copy2(src, bins / b)
        (bins / b).chmod(0o755)

    # Prefer maintained userspace-only installer (backup-first); fall back to embedded INSTALL_SH.
    userspace_src = ROOT / "build-tools" / "install-on-debian-siprec-userspace.sh"
    install = OUT / "install-on-debian-siprec.sh"
    if userspace_src.is_file():
        shutil.copy2(userspace_src, install)
    else:
        install.write_text(INSTALL_SH)
    install.chmod(0o755)

    # Side-by-side test harness (prod-safe). Bins path stays ../bins relative to it.
    sbs_src = ROOT / "build-tools" / "side-by-side-test"
    sbs_dst = OUT / "side-by-side-test"
    if sbs_src.is_dir():
        if sbs_dst.exists():
            shutil.rmtree(sbs_dst)
        shutil.copytree(
            sbs_src,
            sbs_dst,
            ignore=shutil.ignore_patterns(".bin-dir", "__pycache__", "*.pyc"),
        )
        for name in ("run-test.sh", "start-daemon.sh", "start-recording.sh", "smoke-ng.py"):
            p = sbs_dst / name
            if p.exists():
                p.chmod(0o755)

    readme = README_MD.format(SHA=SHA)
    (OUT / "README.md").write_text(readme)
    (OUT / "GIT_SHA").write_text(SHA + "\n")

    print("Package ready:", OUT)
    for p in sorted(OUT.rglob("*")):
        if p.is_file():
            print(" ", p.relative_to(OUT), p.stat().st_size)


INSTALL_SH = r'''#!/bin/bash
# Install matching userspace (+ optional kmod) onto Debian siprec. Run as root.
# ALWAYS backs up current bins/configs before stop/replace.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${ROOT}/bins"
KMOD_DIR="${ROOT}/kmod"
DKMS_DIR="${ROOT}/dkms-src"
TABLE="${TABLE:-42}"

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "==> package root: $ROOT"
echo "==> host kernel:  $(uname -r)"
echo "==> version:      $(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"
echo "==> sha:          $(cat "$ROOT/GIT_SHA" 2>/dev/null || echo unknown)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
need systemctl
need modprobe
need install

TS=$(date +%Y%m%d%H%M%S)
BAK_DIR="/var/backups/rtpengine-rich-logs/${TS}"
mkdir -p "${BAK_DIR}"
DAEMON_PATH="$(command -v rtpengine || true)"; [[ -n "$DAEMON_PATH" ]] || DAEMON_PATH=/usr/bin/rtpengine
REC_PATH="$(command -v rtpengine-recording || true)"; [[ -n "$REC_PATH" ]] || REC_PATH=/usr/bin/rtpengine-recording
[[ -x /usr/sbin/rtpengine-recording ]] && REC_PATH=/usr/sbin/rtpengine-recording

echo "==> backup existing bins BEFORE stop (mandatory) -> ${BAK_DIR}"
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
for f in /etc/systemd/system/rtpengine.service \
         /etc/systemd/system/rtpengine-recording.service \
         /lib/systemd/system/rtpengine.service \
         /lib/systemd/system/rtpengine-recording.service \
         /usr/local/libexec/rtpengine-start.sh \
         /etc/rtpengine.conf \
         /etc/rtpengine-recording.ini; do
  [[ -e "$f" ]] && cp -a "$f" "${BAK_DIR}/$(basename "$f")" || true
done
echo "${DAEMON_PATH}" > "${BAK_DIR}/DAEMON_PATH.txt"
echo "${REC_PATH}" > "${BAK_DIR}/REC_PATH.txt"
ls -la "${BAK_DIR}"

systemctl stop rtpengine rtpengine-recording 2>/dev/null || true
sleep 1
pkill -x rtpengine 2>/dev/null || true
pkill -x rtpengine-recording 2>/dev/null || true

install -m 755 "$BIN_DIR/rtpengine" "$DAEMON_PATH"
install -m 755 "$BIN_DIR/rtpengine-recording" "$REC_PATH"
echo "==> installed userspace:"
file "$DAEMON_PATH" "$REC_PATH"
grep -ao 'recording DETECT' "$DAEMON_PATH" | head -1 || echo "WARN: new log strings missing" >&2
echo "Rollback: cp -a ${DAEMON_PATH}.bak.${TS} ${DAEMON_PATH}; cp -a ${REC_PATH}.bak.${TS} ${REC_PATH}"
echo "Full backup dir: ${BAK_DIR}"

KREL=$(uname -r)
echo "del ${TABLE}" > /proc/rtpengine/control 2>/dev/null || true
modprobe -r xt_RTPENGINE 2>/dev/null || true
modprobe -r nft_rtpengine 2>/dev/null || true

MODULE_LOADED=0
install_ko() {
  local ko="$1" base name
  base=$(basename "$ko"); name=${base%.ko}
  echo "==> installing prebuilt module: $ko as ${name}"
  mkdir -p "/lib/modules/${KREL}/updates"
  install -m 644 "$ko" "/lib/modules/${KREL}/updates/${base}"
  depmod -a "${KREL}"
  modprobe "${name}"
}
for cand in "${KMOD_DIR}/${KREL}/xt_RTPENGINE.ko" "${KMOD_DIR}/${KREL}/nft_rtpengine.ko"; do
  [[ -f "$cand" ]] && install_ko "$cand" && MODULE_LOADED=1 && break || true
done
if [[ "$MODULE_LOADED" -eq 0 ]]; then
  KO=$(find "${KMOD_DIR}" \( -name 'xt_RTPENGINE.ko' -o -name 'nft_rtpengine.ko' \) 2>/dev/null | head -1 || true)
  [[ -n "${KO:-}" ]] && install_ko "$KO" && MODULE_LOADED=1 || true
fi
if [[ "$MODULE_LOADED" -eq 0 ]]; then
  echo "==> keeping/loading existing host module (no matching kmod in package)"
  modprobe xt_RTPENGINE 2>/dev/null || modprobe nft_rtpengine 2>/dev/null || true
fi
lsmod | grep -i rtp || { echo "module still not loaded" >&2; exit 1; }
ls -la /proc/rtpengine/control || { echo "/proc/rtpengine/control missing" >&2; exit 1; }

if [[ -f /etc/rtpengine-recording.ini ]]; then
  cp -a /etc/rtpengine-recording.ini "/etc/rtpengine-recording.ini.bak.${TS}"
  if grep -qE '^[[:space:]]*table[[:space:]]*=' /etc/rtpengine-recording.ini; then
    sed -i -E "s/^[[:space:]]*table[[:space:]]*=.*/table = ${TABLE}/" /etc/rtpengine-recording.ini
  else
    echo "table = ${TABLE}" >> /etc/rtpengine-recording.ini
  fi
fi

systemctl daemon-reload
systemctl restart rtpengine-recording
sleep 1
systemctl restart rtpengine
sleep 2
echo "==> status"
systemctl is-active rtpengine rtpengine-recording
ls -la /proc/rtpengine/ || true
file "$DAEMON_PATH"
echo "DONE. Prefer side-by-side-test before this installer on prod."
'''

README_MD = """# Debian 12.5.1.31 rich recording logs package

Built from branch rich-recording-logs-12.5.1.31 commit {SHA}.

| Path | Content |
|------|---------|
| bins/rtpengine | userspace daemon (rich LOG_NOTICE lifecycle logs) |
| bins/rtpengine-recording | recording-daemon |
| side-by-side-test/ | prod-safe test units (alt ports/table/spool) |
| install-on-debian-siprec.sh | promote installer (ALWAYS backs up first) |
| kmod/ / dkms-src/ | optional matching module artifacts |

## Recommended: side-by-side first (does NOT touch production)

    cd debian-bins/side-by-side-test
    sudo bash run-test.sh install-units
    sudo bash run-test.sh start
    sudo bash run-test.sh status
    sudo bash run-test.sh smoke
    sudo bash run-test.sh stop
    sudo bash run-test.sh uninstall-units

Test uses NG 127.0.0.1:23222, table 44, spool /var/spool/recording-test-12.5.
Production NG/ports/units stay running.

On RHEL lab (not Debian glibc), point BIN_DIR at the canonical RHEL dir:

    BIN_DIR=/path/to/release-bins/12.5.1.31-rich-logs/rhel sudo -E bash run-test.sh install-units

## Promote (after smoke OK)

    cd debian-bins
    sudo bash install-on-debian-siprec.sh

Installer ALWAYS backs up current bins + unit/config files to
/var/backups/rtpengine-rich-logs/<timestamp>/ before stop/replace.

## Verify

    file /usr/bin/rtpengine
    lsmod | grep -i rtp
    sudo journalctl -u rtpengine -u rtpengine-recording -f | grep recording
"""


if __name__ == "__main__":
    main()
