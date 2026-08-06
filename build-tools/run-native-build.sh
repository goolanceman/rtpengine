#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build-tools/logs
LOG="$ROOT/build-tools/logs/native-mac-build.log"

export PATH="/opt/homebrew/bin:/opt/homebrew/opt/mysql-client/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/libxml2/lib/pkgconfig:/opt/homebrew/opt/curl/lib/pkgconfig:/opt/homebrew/opt/mysql-client/lib/pkgconfig:/opt/homebrew/opt/mariadb-connector-c/lib/pkgconfig:/opt/homebrew/opt/libpcap/lib/pkgconfig"
export LDFLAGS="-L/opt/homebrew/lib -L/opt/homebrew/opt/openssl@3/lib -L/opt/homebrew/opt/mysql-client/lib -L/opt/homebrew/opt/libpcap/lib -L/opt/homebrew/opt/gettext/lib"
export CPPFLAGS="-I/opt/homebrew/include -I/opt/homebrew/opt/openssl@3/include -I/opt/homebrew/opt/mysql-client/include -I/opt/homebrew/opt/libpcap/include -I/opt/homebrew/opt/gettext/include"

exec >"$LOG" 2>&1
echo "START $(date)"
echo "PWD=$ROOT"
echo "branch=$(git rev-parse --abbrev-ref HEAD)"
echo "head=$(git rev-parse --short HEAD)"
rm -f config.mk config.mk.new
make -j"$(sysctl -n hw.ncpu)" daemon/rtpengine recording-daemon/rtpengine-recording
rc=$?
echo "MAKE_EXIT=$rc"
ls -la daemon/rtpengine recording-daemon/rtpengine-recording || true
file daemon/rtpengine recording-daemon/rtpengine-recording || true
echo "END $(date)"
exit 0
