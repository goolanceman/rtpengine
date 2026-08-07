#!/bin/bash
# One-shot: force-install debian rich-log rtpengine-recording to /usr/bin and restart.
# Does NOT touch rtpengine media daemon unless FIX_DAEMON=1.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${BIN_DIR:-$REPO/release-bins/12.5.1.31-rich-logs/debian}"
[[ $(id -u) -eq 0 ]] || { echo "sudo $0" >&2; exit 1; }
[[ -x "$SRC/rtpengine-recording" ]] || { echo "missing $SRC/rtpengine-recording" >&2; exit 1; }

TS=$(date +%Y%m%d%H%M%S)
echo "SRC=$SRC"
echo "BEFORE:"; file /usr/bin/rtpengine-recording; sha256sum /usr/bin/rtpengine-recording "$SRC/rtpengine-recording"

cp -a /usr/bin/rtpengine-recording "/usr/bin/rtpengine-recording.bak.${TS}"
install -m 755 "$SRC/rtpengine-recording" /usr/bin/rtpengine-recording
# also /bin if distinct
if [[ -e /bin/rtpengine-recording && "$(readlink -f /bin/rtpengine-recording)" != "$(readlink -f /usr/bin/rtpengine-recording)" ]]; then
  cp -a /bin/rtpengine-recording "/bin/rtpengine-recording.bak.${TS}"
  install -m 755 "$SRC/rtpengine-recording" /bin/rtpengine-recording
fi

if [[ "${FIX_DAEMON:-0}" == "1" ]]; then
  for d in /usr/bin/rtpengine /usr/local/bin/rtpengine; do
    [[ -e "$d" || -d "$(dirname "$d")" ]] || continue
    [[ -x "$SRC/rtpengine" ]] || continue
    cp -a "$d" "${d}.bak.${TS}" 2>/dev/null || true
    install -m 755 "$SRC/rtpengine" "$d"
  done
fi

echo "AFTER:"; file /usr/bin/rtpengine-recording; sha256sum /usr/bin/rtpengine-recording "$SRC/rtpengine-recording"
grep -ao 'recording NEW' /usr/bin/rtpengine-recording | head -1
grep -ao 'status=SAVED' /usr/bin/rtpengine-recording | head -1

systemctl restart rtpengine-recording
sleep 1
systemctl is-active rtpengine-recording
ps -o pid,args= -C rtpengine-recording
R=$(tr '\0' ' ' < /proc/$(pgrep -x rtpengine-recording | head -1)/cmdline | awk '{print $1}')
echo "running=$R"
sha256sum "$R" "$SRC/rtpengine-recording"
strings "$R" | grep -c 'recording NEW'
echo "OK — watch: journalctl -u rtpengine-recording -f | grep recording"
