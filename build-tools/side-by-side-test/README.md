# Side-by-side test (production safe)

Runs the new 12.5.1.31 rich-log binaries under **different unit names**,
ports, spool, and kernel table. Production rtpengine services are
**never stopped, replaced, or restarted**.

## Isolation

| | Production | Test |
|--|--|--|
| Units | rtpengine, rtpengine-recording | rtpengine-test, rtpengine-recording-test |
| Binaries | system path | debian-bins/bins/* |
| NG | 22222 | 127.0.0.1:23222 |
| HTTP | 8080 | 127.0.0.1:18080 |
| CLI | 9900 | 127.0.0.1:19900 |
| RTP ports | 16384-32768 | 40000-42000 |
| Kernel table | 42/43 | 44 (add only) |
| Spool | /var/spool/recording | /var/spool/recording-test-12.5 |
| Output | prod config | /tmp/recordings-test-12.5 |

Needs existing 12.5 module (xt_RTPENGINE). Does not install DKMS.

## Binaries / OS

- On **Debian siprec**: default `debian-bins/bins/` (built against Debian glibc/OpenSSL 3).
- On **RHEL lab**: Debian bins will not run (GLIBC/OpenSSL mismatch). Point at RHEL build:

      BIN_DIR=/path/to/rhel-binaries-12.5.1.31 sudo -E bash run-test.sh install-units

## Commands

    cd debian-bins/side-by-side-test
    # Debian host (default bins):
    sudo bash run-test.sh install-units
    # or RHEL host:
    # BIN_DIR=../../rhel-binaries-12.5.1.31 sudo -E bash run-test.sh install-units
    sudo bash run-test.sh start
    sudo bash run-test.sh status
    sudo bash run-test.sh smoke
    sudo bash run-test.sh logs
    sudo bash run-test.sh stop
    sudo bash run-test.sh uninstall-units

## Promote after smoke OK

    sudo bash run-test.sh stop
    sudo bash run-test.sh uninstall-units
    cd ..
    sudo bash install-on-debian-siprec.sh
