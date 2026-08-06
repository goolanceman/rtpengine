#!/usr/bin/env bash
# Best-effort native build of rtpengine / rtpengine-recording on macOS (Homebrew).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/build-tools/logs}"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/native-mac-build.log"

export PATH="/opt/homebrew/bin:/opt/homebrew/opt/mysql-client/bin:${PATH}"
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:\
/opt/homebrew/opt/openssl@3/lib/pkgconfig:\
/opt/homebrew/opt/libxml2/lib/pkgconfig:\
/opt/homebrew/opt/curl/lib/pkgconfig:\
/opt/homebrew/opt/mysql-client/lib/pkgconfig:\
/opt/homebrew/opt/mariadb-connector-c/lib/pkgconfig:\
/opt/homebrew/opt/libpcap/lib/pkgconfig"
export LDFLAGS="-L/opt/homebrew/lib -L/opt/homebrew/opt/openssl@3/lib \
-L/opt/homebrew/opt/mysql-client/lib -L/opt/homebrew/opt/libpcap/lib \
-L/opt/homebrew/opt/gettext/lib"
export CPPFLAGS="-I/opt/homebrew/include -I/opt/homebrew/opt/openssl@3/include \
-I/opt/homebrew/opt/mysql-client/include -I/opt/homebrew/opt/libpcap/include \
-I/opt/homebrew/opt/gettext/include"

# Apple/BSD needs Darwin feature macros; pure POSIX hides u_char / strncasecmp.
export CFLAGS="${CFLAGS:-} -std=c11 -D_DARWIN_C_SOURCE -D__APPLE_USE_RFC_3542 -Wno-error"
export CPPFLAGS="${CPPFLAGS} -D_DARWIN_C_SOURCE"

{
  echo "=== START $(date) ==="
  echo "branch=$(git rev-parse --abbrev-ref HEAD)"
  echo "head=$(git rev-parse --short HEAD)"
  uname -a
  cc --version | head -n 1

  rm -f config.mk config.mk.new
  # Generate config.mk (deps), then strip GCC-only LTO flags for Apple Clang.
  make config.mk || true
  if [[ ! -f config.mk ]]; then
    # force generate path used by deps makefile
    make -n >/dev/null 2>&1 || true
  fi
  if [[ -f config.mk ]]; then
    # Replace LTO flags Apple Clang rejects
    sed -i.bak \
      -e 's/ -flto=auto//g' \
      -e 's/ -ffat-lto-objects//g' \
      -e 's/ -fuse-linker-plugin//g' \
      config.mk
    echo "patched config.mk for Apple Clang"
    grep CFLAGS_DEFAULT config.mk || true
    grep LDFLAGS_DEFAULT config.mk || true
  fi

  # Also avoid re-adding LTO via gen-common-flags on clean rebuilds:
  # build daemon + recording only
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  echo "make -j${jobs} daemon/rtpengine recording-daemon/rtpengine-recording"
  make -j"${jobs}" \
    CFLAGS="${CFLAGS} -D_DARWIN_C_SOURCE" \
    CPPFLAGS="${CPPFLAGS}" \
    LDFLAGS="${LDFLAGS}" \
    daemon/rtpengine recording-daemon/rtpengine-recording

  echo "=== binaries ==="
  ls -la daemon/rtpengine recording-daemon/rtpengine-recording
  file daemon/rtpengine recording-daemon/rtpengine-recording
  echo "=== END $(date) ==="
} 2>&1 | tee "${LOG}"
