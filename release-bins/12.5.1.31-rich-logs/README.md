# 12.5.1.31 rich-recording-logs binaries

Prebuilt userspace binaries from branch rich-recording-logs-12.5.1.31.

| Path | Target |
|------|--------|
| debian/rtpengine | Debian 13 (trixie) glibc / OpenSSL 3 |
| debian/rtpengine-recording | Debian 13 |
| rhel/rtpengine | RHEL 8 / EL8 |
| rhel/rtpengine-recording | RHEL 8 / EL8 |

Do **not** mix: Debian bins will not run on RHEL (GLIBC/OpenSSL mismatch).

## Side-by-side test (recommended first)

Use build-tools/side-by-side-test (shipped in debian package tarball too):

    # On Debian siprec:
    BIN_DIR=$PWD/release-bins/12.5.1.31-rich-logs/debian sudo -E bash build-tools/side-by-side-test/run-test.sh install-units
    # On RHEL lab:
    BIN_DIR=$PWD/release-bins/12.5.1.31-rich-logs/rhel sudo -E bash build-tools/side-by-side-test/run-test.sh install-units

## Promote (after smoke)

Installer expects package layout with bins/ next to script. Either:

    mkdir -p /tmp/rtp-pkg/bins
    cp release-bins/12.5.1.31-rich-logs/debian/* /tmp/rtp-pkg/bins/
    cp build-tools/install-on-debian-siprec-userspace.sh /tmp/rtp-pkg/install-on-debian-siprec.sh
    sudo bash /tmp/rtp-pkg/install-on-debian-siprec.sh

Or use the packaged tarball from the release machine.
