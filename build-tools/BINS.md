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

## Local / gitignored (not official)

| Path | Role |
|------|------|
| `debian-bins/` | Optional package-assembly staging. Not a bin source. |
| `rhel-binaries/`, `rhel-binaries-*/`, `rhel/` | Removed. Do not recreate. |
| `mac-binaries/` | Generic Docker extract only. Not for siprec/RHEL deploy. |
