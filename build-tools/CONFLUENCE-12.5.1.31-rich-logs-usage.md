# rtpengine 12.5.1.31 Rich Recording Logs — Deployment Guide (Debian siprec)

**Audience:** SIPREC / media operators  
**Branch:** `rich-recording-logs-12.5.1.31`  
**Scope:** Userspace only (`rtpengine` + `rtpengine-recording`). Kernel module / DKMS is **not** changed.  
**Hosts:** Debian siprec (e.g. euprod2-frankfurt-siprec-0x). Use **debian** bins only on these hosts.

---

## 1. What this delivers

Human-friendly **LOG_NOTICE** lifecycle logs for recording:

| Source | Example events |
|--------|----------------|
| **rtpengine** | recording DETECT, START, FINISH, FILE status=CREATED/REMOVED |
| **rtpengine-recording** | recording NEW, STREAM status=OPENED, FILE status=SAVED, FINISH |

Watch both units:

    sudo journalctl -u rtpengine -u rtpengine-recording -f | grep --line-buffered 'recording '

---

## 2. Prerequisites

On the **siprec host**:

    cd ~/rtpengine
    git fetch origin
    git checkout rich-recording-logs-12.5.1.31
    git pull origin rich-recording-logs-12.5.1.31

Confirm release binaries exist (canonical Debian dir only — see `build-tools/BINS.md`):

    ls -la release-bins/12.5.1.31-rich-logs/debian/
    # expect: rtpengine  rtpengine-recording

    file release-bins/12.5.1.31-rich-logs/debian/rtpengine
    file release-bins/12.5.1.31-rich-logs/debian/rtpengine-recording

Rebuild the deploy tarball after replacing bins (filename always ends with UTC datetime):

    ./build-tools/package-rich-logs-tarball.sh
    # → rtpengine-12.5.1.31-rich-logs-YYYYMMDDHHMMSS.tar.gz

Confirm production is 12.5 + xt_RTPENGINE (typical):

    systemctl is-active rtpengine rtpengine-recording
    lsmod | grep -i rtp
    ls /proc/rtpengine/
    grep -E '^table|^spool|^log-level' /etc/rtpengine-recording.ini

**Do not** install release-bins/.../rhel/* on Debian (glibc/OpenSSL mismatch).

---

## 3. Production script (promote / backup / rollback)

Script path:

    build-tools/install-on-debian-siprec-userspace.sh

Always run from repo root (~/rtpengine). Prefer **explicit** BIN_DIR pointing at debian bins.

### 3.1 Commands overview

| Command | Stops prod? | Replaces bins? | Purpose |
|---------|-------------|----------------|---------|
| help | No | No | Show usage |
| status | No | No | Services, paths, rich-log markers, backups |
| list-backups | No | No | List /var/backups/rtpengine-rich-logs/* |
| backup | No | No | Backup current bins/configs only |
| promote | **Yes** | **Yes** | Backup + stop + install rich-log bins + start |
| rollback [id] | **Yes** | Restore | Restore bins (latest or timestamp) |

Aliases: install = promote, restore = rollback.

### 3.2 status (safe)

    cd ~/rtpengine
    sudo bash build-tools/install-on-debian-siprec-userspace.sh status

Check: services active; ExecStart path; OK DETECT on daemon; OK NEW / OK SAVED on recording; running paths match.

### 3.3 backup only (no outage)

    cd ~/rtpengine
    sudo bash build-tools/install-on-debian-siprec-userspace.sh backup
    sudo bash build-tools/install-on-debian-siprec-userspace.sh list-backups

Backup location:

    /var/backups/rtpengine-rich-logs/<YYYYMMDDHHMMSS>/
      rtpengine
      rtpengine-recording
      META.txt
      DAEMON_PATH.txt
      REC_PATH.txt

Also: /var/backups/rtpengine-rich-logs/latest → last TS  
Sibling copies: /usr/bin/rtpengine-recording.bak.<TS> etc.

### 3.4 promote (production cutover)

**Short media/recording blip.** Kernel module and /etc/rtpengine-recording.ini are not rewritten.

    cd ~/rtpengine

    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote

Without BIN_DIR, first match wins:

1. BIN_DIR env
2. packaged `bins/` next to the script
3. OS-matched `release-bins/12.5.1.31-rich-logs/{debian|rhel}`

See `build-tools/BINS.md`. Do not use `rhel-binaries/` or `debian-bins/bins`.

Promote steps: resolve all install paths → mandatory backup → stop both services → install both bins (forces /usr/bin/rtpengine-recording) → sha256 + string verify → start → verify running /proc/MainPID/exe.

Must finish with success (example):

    OK running-daemon has recording DETECT @ ...
    OK running-recording has recording NEW @ /usr/bin/rtpengine-recording
    OK running-recording has status=SAVED @ /usr/bin/rtpengine-recording
    recording src sha=...  run sha=...   (must be equal)
    PROMOTE DONE

If hash mismatch: do not ignore — recording binary is still wrong.

### 3.5 Verify after promote

    sudo bash build-tools/install-on-debian-siprec-userspace.sh status

    file /usr/bin/rtpengine-recording \
         release-bins/12.5.1.31-rich-logs/debian/rtpengine-recording
    sha256sum /usr/bin/rtpengine-recording \
              release-bins/12.5.1.31-rich-logs/debian/rtpengine-recording

    systemctl is-active rtpengine rtpengine-recording
    ps -o pid,args= -C rtpengine,rtpengine-recording
    pid=$(systemctl show -p MainPID --value rtpengine-recording)
    sudo readlink -f /proc/$pid/exe
    sudo strings "$(sudo readlink -f /proc/$pid/exe)" | grep -c 'recording NEW'

    sudo journalctl -u rtpengine -u rtpengine-recording -f | grep --line-buffered 'recording '

After a **new** recorded call: daemon DETECT/START and recording NEW/STREAM/FILE/FINISH.

### 3.6 rollback

    sudo bash build-tools/install-on-debian-siprec-userspace.sh list-backups
    sudo bash build-tools/install-on-debian-siprec-userspace.sh rollback latest
    # or:
    sudo bash build-tools/install-on-debian-siprec-userspace.sh rollback 20260807123000

Rollback: safety copy to pre-rollback-<TS>/ → stop → restore bins → start.

    sudo bash build-tools/install-on-debian-siprec-userspace.sh status

---

## 4. Emergency: recording binary only

If BuildIDs differ for /usr/bin/rtpengine-recording vs release-bins debian:

    cd ~/rtpengine
    git pull origin rich-recording-logs-12.5.1.31
    sudo bash build-tools/fix-recording-bin-on-siprec.sh

Optional also daemon:

    FIX_DAEMON=1 sudo -E bash build-tools/fix-recording-bin-on-siprec.sh

---

## 5. Side-by-side test (optional, before promote)

Production is **not** stopped or replaced.

| | Production (typical siprec) | Test |
|--|--|--|
| Units | rtpengine, rtpengine-recording | rtpengine-test, rtpengine-recording-test |
| NG | 22222 | 127.0.0.1:23222 |
| RTP | 40000-60000 | 61000-62998 |
| Table | 42 | 44 (add only) |
| Spool | /var/spool/recording | /var/spool/recording-test-12.5 |
| WAV out | /tmp/recordings | /tmp/recordings-test-12.5 |
| Config | /etc/rtpengine-recording.ini | harness test ini |

    cd ~/rtpengine

    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/side-by-side-test/run-test.sh install-units

    # optional: LOCAL_IP=172.15.20.253 sudo -E bash ... start
    sudo bash build-tools/side-by-side-test/run-test.sh start
    sudo bash build-tools/side-by-side-test/run-test.sh status
    sudo bash build-tools/side-by-side-test/run-test.sh smoke
    sudo bash build-tools/side-by-side-test/run-test.sh logs
    sudo bash build-tools/side-by-side-test/run-test.sh stop
    sudo bash build-tools/side-by-side-test/run-test.sh uninstall-units

---

## 6. Recommended production order

1. git pull on siprec  
2. status (baseline)  
3. Optional side-by-side smoke  
4. Optional backup  
5. Maintenance window — promote with BIN_DIR (section 3.4)  
6. Verify hashes + status + journal  
7. If bad: rollback latest  

---

## 7. What promote does NOT change

- Kernel module (xt_RTPENGINE / DKMS)  
- Kernel table number (e.g. 42)  
- /etc/rtpengine-recording.ini (table, spool, output-dir, pattern)  
- Production listen ports / start-script interfaces  

---

## 8. Troubleshooting

**Rich logs on rtpengine only, not recording**  
Usually old /usr/bin/rtpengine-recording still on ExecStart. Compare file/sha256sum to release-bins debian; re-run promote or fix-recording-bin-on-siprec.sh.

**Only AMR/ffmpeg ERR**  
Not lifecycle logs. Look for literal "recording NEW" / "recording FILE".

**Promote hash mismatch**  
Script refused success; fix and re-promote.

---

## 9. Cheat sheet

    cd ~/rtpengine
    git pull origin rich-recording-logs-12.5.1.31

    sudo bash build-tools/install-on-debian-siprec-userspace.sh status
    sudo bash build-tools/install-on-debian-siprec-userspace.sh list-backups
    sudo bash build-tools/install-on-debian-siprec-userspace.sh backup

    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote

    sudo bash build-tools/install-on-debian-siprec-userspace.sh rollback latest
    # sudo bash build-tools/install-on-debian-siprec-userspace.sh rollback YYYYMMDDHHMMSS

    sudo bash build-tools/fix-recording-bin-on-siprec.sh

    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/side-by-side-test/run-test.sh install-units
    sudo bash build-tools/side-by-side-test/run-test.sh start
    sudo bash build-tools/side-by-side-test/run-test.sh smoke
    sudo bash build-tools/side-by-side-test/run-test.sh stop
    sudo bash build-tools/side-by-side-test/run-test.sh uninstall-units

    sudo journalctl -u rtpengine -u rtpengine-recording -f | grep --line-buffered 'recording '

---

## 10. Paths reference

| Item | Path |
|------|------|
| Branch | rich-recording-logs-12.5.1.31 |
| **Debian bins (only)** | `release-bins/12.5.1.31-rich-logs/debian/` |
| **RHEL bins (only)** | `release-bins/12.5.1.31-rich-logs/rhel/` |
| Bin-dir policy | `build-tools/BINS.md` |
| Deploy tarball script | `build-tools/package-rich-logs-tarball.sh` |
| Promote/rollback script | build-tools/install-on-debian-siprec-userspace.sh |
| Recording emergency fix | build-tools/fix-recording-bin-on-siprec.sh |
| Side-by-side harness | build-tools/side-by-side-test/ |
| Prod backups | /var/backups/rtpengine-rich-logs/ |
| Typical recording binary | /usr/bin/rtpengine-recording |
| Typical recording config | /etc/rtpengine-recording.ini |
| Typical unit | /etc/systemd/system/rtpengine-recording.service |

---

Keep this page updated when promote script or release-bins layout changes.
