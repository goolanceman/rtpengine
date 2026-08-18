# 12.5.1.31 rich-recording-logs binaries

**This is the only official bin location.** See `build-tools/BINS.md`.

| Path | Target |
|------|--------|
| debian/rtpengine | Debian 13 (trixie) glibc / OpenSSL 3 |
| debian/rtpengine-recording | Debian 13 |
| rhel/rtpengine | RHEL 8 / EL8 |
| rhel/rtpengine-recording | RHEL 8 / EL8 |

Do **not** mix: Debian bins will not run on RHEL (GLIBC/OpenSSL mismatch).
Do **not** keep extra copies (`rhel-binaries/`, `rhel-binaries-12.5.1.31/`, `rhel/bins/`, `debian-bins/bins` as a source).

Recording mixer: stream-pin + 1s idle-guard. Overlapping SSRCs on one SIPREC
stream keep separate slots (AMR SID + speech). Hold/resume still reuses after
1s quiet. Packager requires both mixer markers.

Rebuild the deploy tarball after replacing bins (datetime is appended):

    ./build-tools/package-rich-logs-tarball.sh
    # → rtpengine-12.5.1.31-rich-logs-YYYYMMDDHHMMSS.tar.gz

## Side-by-side test (recommended first)

    # On Debian siprec:
    BIN_DIR=$PWD/release-bins/12.5.1.31-rich-logs/debian sudo -E bash build-tools/side-by-side-test/run-test.sh install-units
    # On RHEL lab:
    BIN_DIR=$PWD/release-bins/12.5.1.31-rich-logs/rhel sudo -E bash build-tools/side-by-side-test/run-test.sh install-units

## Promote (after smoke)

    BIN_DIR=$PWD/release-bins/12.5.1.31-rich-logs/debian \
      sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote
    # RHEL lab:
    # BIN_DIR=$PWD/release-bins/12.5.1.31-rich-logs/rhel sudo -E bash ... promote

