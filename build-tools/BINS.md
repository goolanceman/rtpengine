# Canonical binary directories (12.5.1.31 rich-logs)

Use **one directory per OS**. Do not keep extra copies (`rhel-binaries/`,
`rhel-binaries-12.5.1.31/`, `rhel/bins/`, `debian-bins/bins/` for deploy).

| OS | Directory | Binaries |
|----|-----------|----------|
| Debian 13 (siprec) | `release-bins/12.5.1.31-rich-logs/debian/` | `rtpengine`, `rtpengine-recording` |
| RHEL 8 / EL8 (lab) | `release-bins/12.5.1.31-rich-logs/rhel/` | `rtpengine`, `rtpengine-recording` |

Do **not** mix: Debian bins will not run on RHEL (GLIBC / OpenSSL mismatch).

## How scripts find bins

`BIN_DIR` always wins. Otherwise:

1. Promote / rollback (`install-on-debian-siprec-userspace.sh`): OS-matched
   `release-bins/.../{debian,rhel}`, then packaged `bins/` next to the script.
2. Side-by-side test (`run-test.sh`): `.bin-dir` from last `install-units`,
   packaged `../bins`, then OS-matched `release-bins/.../{debian,rhel}`.
3. Docker extract:
   - Debian: `OUT_DIR=release-bins/12.5.1.31-rich-logs/debian ./build-tools/docker-build-binaries.sh`
   - RHEL: `./build-tools/docker-build-rhel-binaries.sh` (defaults to the rhel dir above)

## Build the deploy tarball

```bash
# from repo root — always writes a new dated file
./build-tools/package-rich-logs-tarball.sh
# optional prefix (datetime is still appended):
OUT=/tmp/rtpengine-12.5.1.31-rich-logs.tar.gz ./build-tools/package-rich-logs-tarball.sh
```

Output: `rtpengine-12.5.1.31-rich-logs-<UTC YYYYMMDDHHMMSS>.tar.gz`.
Previous dated tarballs are left in place (not overwritten).
The packager refuses bins that lack both mixer markers:

- `Re-using mix input index #%u for new SSRC on same stream`
- `Not re-using mix input index #%u: previous SSRC still active`

Verify after a rebuild:

```bash
python3 build-tools/side-by-side-test/test-mix-index.py
# side-by-side (does not touch prod):
#   sudo bash build-tools/side-by-side-test/run-test.sh smoke
#   sudo python3 build-tools/side-by-side-test/smoke-mixer.py
# expect 0 x "old re-used input channel"
```

## Debian SIPREC cluster deployment

Use `deploy-debian-siprec-cluster.sh` when the Debian binaries must be built,
packaged, copied, and promoted to both SIPREC hosts. The script uses the SSH
aliases in `~/.ssh/config`; the verified Frankfurt aliases are:

- `euprod2-frankfurt-siprec-01` (SSH user `mansoor` from SSH config)
- `euprod2-frankfurt-siprec-02` (SSH user `mansoor` from SSH config)

Build and create a checksum-protected tarball without changing hosts:

```bash
./build-tools/deploy-debian-siprec-cluster.sh
```

Promote the generated Debian userspace binaries sequentially:

```bash
./build-tools/deploy-debian-siprec-cluster.sh --promote \
  euprod2-frankfurt-siprec-01 euprod2-frankfurt-siprec-02
```

The script builds with Docker, verifies the archive checksum after `scp`,
extracts under `/var/tmp/rtpengine-rich-logs-deploy`, and invokes the
backup-first installer on one host at a time. It verifies both
`rtpengine.service` and `rtpengine-recording.service` before proceeding to the
next host. The installer creates backups under
`/var/backups/rtpengine-rich-logs/`; the kernel module is not changed.

To use another SSH user or host pair, set `SSH_USER` or pass explicit host
arguments. To reuse the canonical binaries without rebuilding and choose the
archive output path, use `--no-build --archive PATH --promote HOST1 HOST2`.
The canonical Debian binaries must still be available because the archive is
assembled locally before copying.

If a host fails verification, promotion stops before the next host. Inspect
the service status and use the host's latest backup for rollback:

```bash
sudo bash build-tools/install-on-debian-siprec-userspace.sh list-backups
sudo bash build-tools/install-on-debian-siprec-userspace.sh rollback latest
```

## Local / gitignored (not official)

| Path | Role |
|------|------|
| `debian-bins/` | Optional package-assembly staging. Not a bin source. |
| `rhel-binaries/`, `rhel-binaries-*/`, `rhel/` | Removed. Do not recreate. |
| `mac-binaries/` | Generic Docker extract only. Not for siprec/RHEL deploy. |
