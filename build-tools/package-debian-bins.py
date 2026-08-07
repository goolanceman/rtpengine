#!/usr/bin/env python3
"""Assemble debian-bins deploy package (bins + kmod extract + install script)."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "debian-bins"
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
    if not (bins / "rtpengine").exists():
        env = os.environ.copy()
        env["OUT_DIR"] = str(bins)
        env["IMAGE_DAEMON"] = "rtpengine-debian-trixie:daemon"
        env["IMAGE_RECORDING"] = "rtpengine-debian-trixie:recording"
        env["DOCKERFILE"] = "Dockerfile"
        subprocess.check_call([str(ROOT / "build-tools" / "docker-build-binaries.sh")], cwd=ROOT, env=env)

    for b in ("rtpengine", "rtpengine-recording"):
        p = bins / b
        p.chmod(0o755)

    install = OUT / "install-on-debian-siprec.sh"
    install.write_text(INSTALL_SH)
    install.chmod(0o755)

    readme = README_MD.format(SHA=SHA)
    (OUT / "README.md").write_text(readme)

    print("Package ready:", OUT)
    for p in sorted(OUT.rglob("*")):
        if p.is_file():
            print(" ", p.relative_to(OUT), p.stat().st_size)


INSTALL_SH = r'''#!/bin/bash
# Install matching userspace + kernel module onto Debian 13 siprec. Run as root.
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

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
need systemctl
need modprobe

systemctl stop rtpengine rtpengine-recording 2>/dev/null || true
sleep 1
pkill -x rtpengine 2>/dev/null || true
pkill -x rtpengine-recording 2>/dev/null || true

install -m 755 "$BIN_DIR/rtpengine" /usr/bin/rtpengine
install -m 755 "$BIN_DIR/rtpengine-recording" /usr/bin/rtpengine-recording
echo "==> installed userspace:"
file /usr/bin/rtpengine /usr/bin/rtpengine-recording
grep -ao 'recording DETECT' /usr/bin/rtpengine | head -1 || echo "WARN: new log strings missing" >&2

KREL=$(uname -r)
echo "del ${TABLE}" > /proc/rtpengine/control 2>/dev/null || true
modprobe -r xt_RTPENGINE 2>/dev/null || true
modprobe -r nft_rtpengine 2>/dev/null || true
command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -i rtpengine || true

install_ko() {
  local ko="$1"
  echo "==> installing prebuilt module: $ko"
  mkdir -p "/lib/modules/${KREL}/updates"
  install -m 644 "$ko" "/lib/modules/${KREL}/updates/nft_rtpengine.ko"
  depmod -a "${KREL}"
  modprobe nft_rtpengine
}

MODULE_LOADED=0
if [[ -f "${KMOD_DIR}/${KREL}/nft_rtpengine.ko" ]]; then
  install_ko "${KMOD_DIR}/${KREL}/nft_rtpengine.ko" && MODULE_LOADED=1 || true
fi
if [[ "$MODULE_LOADED" -eq 0 ]]; then
  KO=$(find "${KMOD_DIR}" -name 'nft_rtpengine.ko' 2>/dev/null | head -1 || true)
  if [[ -n "${KO:-}" ]]; then
    echo "==> no exact match for ${KREL}; trying $KO"
    install_ko "$KO" && MODULE_LOADED=1 || echo "prebuilt .ko load failed; will try DKMS"
  fi
fi

if [[ "$MODULE_LOADED" -eq 0 ]]; then
  echo "==> DKMS build for ${KREL}"
  need dkms
  if [[ ! -d "/lib/modules/${KREL}/build" ]]; then
    apt-get update -qq
    apt-get install -y "linux-headers-${KREL}" dkms build-essential || \
      apt-get install -y linux-headers-amd64 dkms build-essential
  fi
  SRC_DIR=$(find "${DKMS_DIR}" -maxdepth 1 -type d -name 'ngcp-rtpengine-*' | head -1)
  [[ -n "$SRC_DIR" ]] || { echo "no DKMS src under ${DKMS_DIR}" >&2; exit 1; }
  PKG=$(basename "$SRC_DIR")
  VER=${PKG#ngcp-rtpengine-}
  rm -rf "/usr/src/${PKG}"
  mkdir -p "/usr/src/${PKG}"
  cp -a "${SRC_DIR}/." "/usr/src/${PKG}/"
  if [[ ! -f "/usr/src/${PKG}/dkms.conf" ]]; then
    cat > "/usr/src/${PKG}/dkms.conf" <<DKMS
PACKAGE_NAME="ngcp-rtpengine"
PACKAGE_VERSION="${VER}"
BUILD_EXCLUSIVE_KERNEL_MIN="4.4"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build RTPENGINE_VERSION=\\\"\${PACKAGE_VERSION}\\\""
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
AUTOINSTALL=yes
BUILT_MODULE_NAME[0]="nft_rtpengine"
DEST_MODULE_LOCATION[0]=/extra
DKMS
  fi
  dkms remove "ngcp-rtpengine/${VER}" --all 2>/dev/null || true
  dkms remove rtpengine/12.5.1.31 --all 2>/dev/null || true
  dkms remove ngcp-rtpengine/12.5.1.31 --all 2>/dev/null || true
  dkms add -m ngcp-rtpengine -v "${VER}"
  dkms build -m ngcp-rtpengine -v "${VER}" -k "${KREL}"
  dkms install -m ngcp-rtpengine -v "${VER}" -k "${KREL}"
  modprobe nft_rtpengine
fi

lsmod | grep -i rtp || { echo "module still not loaded" >&2; exit 1; }
ls -la /proc/rtpengine/control || { echo "/proc/rtpengine/control missing" >&2; exit 1; }

mkdir -p /etc/systemd/system/rtpengine.service.d
cat > /etc/systemd/system/rtpengine.service.d/10-xtables-match.conf <<UNIT
[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=/bin/bash -c '\\
  LOCAL_IP=\$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 || hostname -I | awk "{print \\\$1}"); \\
  echo "del ${TABLE}" > /proc/rtpengine/control 2>/dev/null || true; \\
  exec /usr/bin/rtpengine \\
    --interface private/\${LOCAL_IP} \\
    --interface public/\${LOCAL_IP} \\
    --listen-ng=22222 --listen-http=8080 --listen-udp=12222 \\
    --dtmf-log-dest=127.0.0.1:22223 --listen-cli=127.0.0.1:9900 \\
    --table=${TABLE} --xtables \\
    --pidfile /run/rtpengine.pid \\
    --port-min 40000 --port-max 60000 \\
    --recording-dir /var/spool/recording \\
    --recording-method proc \\
    --log-level 5 --delete-delay 0 --foreground'
UNIT

if [[ -f /etc/rtpengine-recording.ini ]]; then
  cp -a /etc/rtpengine-recording.ini "/etc/rtpengine-recording.ini.bak.$(date +%s)"
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
ps -o args= -C rtpengine | head -1
ls -la /proc/rtpengine/${TABLE}/control || ls -la /proc/rtpengine/*/control || true
file /usr/bin/rtpengine
journalctl -u rtpengine --since '30 sec ago' --no-pager | grep -iE 'FAILED|KERNEL|version|OPEN' || echo '(no kernel errors)'
echo "DONE. Expect after a call: recording DETECT / START kernel_open=1 / FILE status=CREATED"
'''

README_MD = """# Debian 13 (trixie) matching userspace + kernel module

Built from branch rich-recording-debug-logs commit {SHA}.

| Path | Content |
|------|---------|
| bins/rtpengine | userspace daemon (human-friendly LOG_NOTICE) |
| bins/rtpengine-recording | recording-daemon |
| kmod/KVER/nft_rtpengine.ko | prebuilt module for Debian headers used at build |
| dkms-src/ | DKMS sources for host uname -r |
| install-on-debian-siprec.sh | one-shot installer |

## Why

Host packages were 12.5.1.31-1. Replacing only userspace with 26.x bins breaks
proc table open. This package ships matching userspace + kernel module.

## Install on siprec

scp -r debian-bins movius@euprod2-frankfurt-siprec-01:~/
cd ~/debian-bins && sudo ./install-on-debian-siprec.sh

If prebuilt .ko vermagic mismatches host kernel, installer falls back to DKMS
(needs linux-headers for uname -r).

## Verify

file /usr/bin/rtpengine
lsmod | grep nft_rtpengine
ls -la /proc/rtpengine/42/control
ps -o args= -C rtpengine | grep xtables
sudo journalctl -u rtpengine -n 50 | grep -E 'recording DETECT|FAILED TO OPEN'
"""


if __name__ == "__main__":
    main()
