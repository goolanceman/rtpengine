# rtpengine 11.5.1.24 rich recording + call QoS logs

Userspace binaries only (daemon + recording). Match kernel module 11.5.

## Layout
- debian/ — bookworm-built bins
- rhel/ — Rocky/RHEL 8-built bins
- rtpengine-11.5.1.24-rich-logs-*.tar.gz — full deploy tarball

## Promote (Debian siprec)

    BIN_DIR=$PWD/release-bins/11.5.1.24-rich-logs/debian \
      sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote

See build-tools/CONFLUENCE-11.5.1.24-rich-logs-usage.md.
