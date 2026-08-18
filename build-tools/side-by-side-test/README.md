# Side-by-side test (production safe)

Runs the new 12.5.1.31 rich-log binaries under **different unit names**,
ports, spool, and kernel table. Production rtpengine services are
**never stopped, replaced, or restarted**.

## Isolation

| | Production (siprec) | Test |
|--|--|--|
| Units | rtpengine, rtpengine-recording | rtpengine-test, rtpengine-recording-test |
| Binaries | /usr/bin/* | package bins/ or BIN_DIR |
| NG | 22222 | 127.0.0.1:23222 |
| HTTP | 8080 | 127.0.0.1:18080 |
| UDP ctrl | 12222 | 127.0.0.1:13222 |
| CLI | 127.0.0.1:9900 | 127.0.0.1:19900 |
| DTMF log | 127.0.0.1:22223 | (not used) |
| RTP ports | 40000-60000 | 61000-62998 (no overlap) |
| Kernel table | 42 | 44 (add only; never del 42) |
| PID file | /run/rtpengine.pid | /run/rtpengine-test-12.5.pid |
| Recording config | /etc/rtpengine-recording.ini | side-by-side-test/rtpengine-recording-test.ini |
| Spool (meta/pcap) | /var/spool/recording | /var/spool/recording-test-12.5 |
| WAV output-dir | /tmp/recordings | /tmp/recordings-test-12.5 |
| output-pattern | .../rtpengine-%c-%t-M%S%u | .../test-%c-%t-M%S%u |
| output-format / mix | wav, mixed, channels, 8k | same as prod |

Needs existing 12.5 module (xt_RTPENGINE). Does not install DKMS.

## Binaries / OS

One dir per OS (see `build-tools/BINS.md`). Do not use `rhel-binaries/` or `debian-bins/bins`.

- **Debian siprec:** `release-bins/12.5.1.31-rich-logs/debian/`
- **RHEL lab:** `release-bins/12.5.1.31-rich-logs/rhel/` (Debian bins will not run)

## Commands

    cd ~/rtpengine
    # Debian siprec:
    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/side-by-side-test/run-test.sh install-units
    # RHEL lab:
    # BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/rhel" \
    #   sudo -E bash build-tools/side-by-side-test/run-test.sh install-units
    sudo bash build-tools/side-by-side-test/run-test.sh start
    sudo bash build-tools/side-by-side-test/run-test.sh status
    sudo bash build-tools/side-by-side-test/run-test.sh smoke
    sudo bash build-tools/side-by-side-test/run-test.sh logs
    sudo bash build-tools/side-by-side-test/run-test.sh stop
    sudo bash build-tools/side-by-side-test/run-test.sh uninstall-units

## Promote after smoke OK

    sudo bash run-test.sh stop
    sudo bash run-test.sh uninstall-units
    cd ..
    sudo bash install-on-debian-siprec.sh
