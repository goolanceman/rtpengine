#!/usr/bin/env bash
# Install rhel-binaries + shared libs, configure systemd drop-ins, start units, NG smoke.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_DIR="${BIN_DIR:-${ROOT_DIR}/rhel-binaries}"
LIB_DIR="${LIB_DIR:-${BIN_DIR}/lib}"
IMAGE="${IMAGE:-rtpengine-rhel8-build:local}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/build-tools/logs}"
mkdir -p "${LOG_DIR}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need sudo; need systemctl; need python3; need docker

[[ -x "${BIN_DIR}/rtpengine" ]] || { echo "missing ${BIN_DIR}/rtpengine" >&2; exit 1; }
[[ -x "${BIN_DIR}/rtpengine-recording" ]] || { echo "missing recording binary" >&2; exit 1; }

echo "==> bundle runtime libs from ${IMAGE} if needed"
if [[ ! -d "${LIB_DIR}" ]] || [[ -z "$(ls -A "${LIB_DIR}" 2>/dev/null || true)" ]]; then
  mkdir -p "${LIB_DIR}"
  docker run --rm --entrypoint bash "${IMAGE}" -lc '
    set -e; mkdir -p /tmp/libbundle
    for bin in /out/rtpengine /out/rtpengine-recording; do
      ldd "$bin" | awk "/=> \\// {print \$3}"
    done | sort -u > /tmp/libs.list
    while read -r so; do
      [ -f "$so" ] || continue
      base=$(basename "$so")
      case "$base" in
        libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|libresolv.so.*|librt.so.*|ld-linux*.so.*) continue ;;
      esac
      cp -aL "$so" /tmp/libbundle/ 2>/dev/null || cp -a "$so" /tmp/libbundle/
    done < /tmp/libs.list
    cd /tmp/libbundle && tar cf - .
  ' | tar xf - -C "${LIB_DIR}"
fi

echo "==> stop conflicts"
docker stop rtpengine 2>/dev/null || true
sudo systemctl stop rtpengine-native rtpengine rtpengine-recording 2>/dev/null || true

echo "==> install"
TS="$(date +%Y%m%d%H%M%S)"
sudo mkdir -p /usr/local/lib /usr/local/libexec
[[ -e /usr/local/bin/rtpengine ]] && sudo cp -a /usr/local/bin/rtpengine "/usr/local/bin/rtpengine.bak.${TS}" || true
[[ -e /usr/bin/rtpengine-recording ]] && sudo cp -a /usr/bin/rtpengine-recording "/usr/bin/rtpengine-recording.bak.${TS}" || true
sudo install -m 0755 "${BIN_DIR}/rtpengine" /usr/local/bin/rtpengine
sudo install -m 0755 "${BIN_DIR}/rtpengine-recording" /usr/bin/rtpengine-recording
sudo cp -a "${LIB_DIR}/." /usr/local/lib/
LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/rtpengine --version
LD_LIBRARY_PATH=/usr/local/lib /usr/bin/rtpengine-recording --version

sudo tee /usr/local/libexec/rtpengine-start.sh >/dev/null <<'EOF'
#!/bin/bash
set -e
export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
LOCAL_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 || hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "$LOCAL_IP")
TABLE=42; METHOD=proc
[ -e /proc/rtpengine/control ] || { TABLE=-1; METHOD=pcap; }
exec /usr/local/bin/rtpengine \
  --interface "private/${LOCAL_IP}" --interface "public/${LOCAL_IP}!${PUBLIC_IP}" \
  --listen-ng=22222 --listen-http=8080 --listen-udp=12222 \
  --dtmf-log-dest=127.0.0.1:22223 --listen-cli=127.0.0.1:9900 \
  --table="${TABLE}" --pidfile /run/rtpengine.pid \
  --port-min 16384 --port-max 32768 \
  --recording-dir /var/spool/recording --recording-method "${METHOD}" \
  --log-level 5 --delete-delay 0 --foreground \
  --homer=127.0.0.1:9060 --homer-protocol=udp --homer-id=99 --mos=LQ
EOF
sudo chmod 755 /usr/local/libexec/rtpengine-start.sh

sudo mkdir -p /etc/systemd/system/rtpengine.service.d /etc/systemd/system/rtpengine-recording.service.d
sudo tee /etc/systemd/system/rtpengine.service.d/20-rhel-local.conf >/dev/null <<'EOF'
[Service]
CPUSchedulingPolicy=other
IOSchedulingClass=best-effort
Type=simple
PIDFile=
Environment=LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64
ExecStartPre=
ExecStartPre=/bin/bash -c 'mkdir -p /var/spool/recording/{metadata,pcaps,tmp,wav} /tmp/recordings; chmod -R a+rwx /var/spool/recording /tmp/recordings || true'
ExecStartPre=/bin/bash -c 'echo del 42 > /proc/rtpengine/control 2>/dev/null || true'
ExecStart=
ExecStart=/bin/bash /usr/local/libexec/rtpengine-start.sh
EOF
sudo tee /etc/systemd/system/rtpengine-recording.service.d/20-rhel-local.conf >/dev/null <<'EOF'
[Service]
CPUSchedulingPolicy=other
IOSchedulingClass=best-effort
Type=simple
Environment=LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64
ExecStart=
ExecStart=/usr/bin/rtpengine-recording --config-file=/etc/rtpengine-recording.ini --foreground
EOF
sudo sed -i 's/^log-level.*/log-level = 5/' /etc/rtpengine-recording.ini || true

sudo systemctl daemon-reload
sudo systemctl reset-failed rtpengine rtpengine-recording 2>/dev/null || true
sudo systemctl start rtpengine; sleep 2
sudo systemctl start rtpengine-recording; sleep 2
systemctl is-active rtpengine; systemctl is-active rtpengine-recording

echo "==> NG smoke"
python3 - <<'PY' | tee "${LOG_DIR}/systemd-smoke.log"
import socket, time, uuid
def benc(o):
    if isinstance(o, dict):
        return b'd'+b''.join(benc(k)+benc(v) for k,v in sorted(o.items()))+b'e'
    if isinstance(o, int): return f'i{o}e'.encode()
    if isinstance(o, str):
        b=o.encode(); return f'{len(b)}:'.encode()+b
    raise TypeError
def ng(cmd):
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3)
    c=f"t{int(time.time()*1e6)}"
    s.sendto(c.encode()+b' '+benc(cmd),('127.0.0.1',22222))
    print(s.recvfrom(65535)[0][:140])
sdp=("v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=s\r\nc=IN IP4 127.0.0.1\r\n"
     "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n")
cid=f'sysd-{uuid.uuid4().hex[:8]}'
ng({'command':'ping'})
ng({'command':'offer','call-id':cid,'from-tag':'A','record-call':'yes','sdp':sdp})
ng({'command':'offer','call-id':cid,'from-tag':'A','record-call':'yes','sdp':sdp})
ng({'command':'offer','call-id':cid+'-i','from-tag':'A','record-call':'foo','sdp':sdp})
ng({'command':'delete','call-id':cid,'from-tag':'A'})
print('call-id', cid)
PY
sleep 1
sudo journalctl -u rtpengine -n 80 --no-pager | \
  grep -E 'recording (detect|start|already-active|stop|finish)' | tee -a "${LOG_DIR}/systemd-smoke.log" || true
echo "done. smoke: ${LOG_DIR}/systemd-smoke.log"
