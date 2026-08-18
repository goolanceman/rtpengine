# rtpengine Docker image — build & usage guide

Standard **Debian trixie (GNU/Linux)** image built from the current git checkout.
Contains **both** binaries:

| Binary | Path in image | Role |
|--------|---------------|------|
| `rtpengine` | `/usr/local/bin/rtpengine` | Media proxy (NG control, RTP relay, recording export) |
| `rtpengine-recording` | `/usr/local/bin/rtpengine-recording` | Recording daemon (decode spool to file/S3/GCS + lifecycle HTTP notify) |

Verified on `rtpengine:local`:

```text
-rwxr-xr-x  /usr/local/bin/rtpengine            (~1.7 MB)
-rwxr-xr-x  /usr/local/bin/rtpengine-recording  (~400 KB)
Version: 26.2.0.0+0~mr26.2.0.0
YES_BOTH
```

Default image `CMD` starts **rtpengine** only. Start **rtpengine-recording** with an
explicit entrypoint/command (see section 5).

---

## 1. Build the image

Prerequisites: Docker Desktop running, repo checked out on the desired branch.

```bash
# from repo root
./build-tools/build-linux-image.sh
```

Tags produced (same image):

- `rtpengine:<branch>-<shortsha>` — e.g. `rtpengine:recording-notify-lifecycle-pr-a1ae9522`
- `rtpengine:local`
- `rtpengine-recording-notify:local`

Base OS: **debian:trixie-slim**. Architecture follows the Docker engine
(`linux/arm64` on Apple Silicon, `linux/amd64` on Intel).

Optional — extract bare ELF binaries only into `./mac-binaries/`:

```bash
./build-tools/docker-build-binaries.sh
file mac-binaries/*
```

---

## 2. Quick sanity checks

```bash
docker run --rm --entrypoint rtpengine rtpengine:local --version
docker run --rm --entrypoint rtpengine-recording rtpengine:local --version
docker run --rm --entrypoint rtpengine rtpengine:local --help | head
docker run --rm --entrypoint rtpengine-recording rtpengine:local --help | head

# prove both binaries exist in one shot
docker run --rm --entrypoint /bin/bash rtpengine:local -lc \
  'ls -la /usr/local/bin/rtpengine /usr/local/bin/rtpengine-recording'
```

---

## 3. How the two daemons work together

```text
  Kamailio / SIP core
         |  NG protocol (:22222)
         v
   +-----------+   pcap/meta on shared volume    +----------------------+
   | rtpengine | ------------------------------> | rtpengine-recording  |
   | (media)   |    recording-dir = /rec         | spool-dir = /rec      |
   +-----------+                                 +----------------------+
         ^                                                |
         | RTP                                            | HTTP lifecycle
         v                                                v
      endpoints                              notify-uri (your webhook)
                                             + output-dir / S3 / GCS
```

1. **rtpengine** writes metadata + captured packets under `recording-dir`.
2. **rtpengine-recording** watches the same path as `spool-dir` (inotify).
3. It decodes audio and emits **lifecycle notifications** to `notify-uri`.

Both processes **must share the same volume** for the spool directory.
`recording-dir` (rtpengine) and `spool-dir` (recording) must be the **same path**.

---

## 4. Run rtpengine (media proxy)

The image entrypoint expands `MY_IP` in `docker/rtpengine.conf` and runs
`rtpengine --config-file rtpengine.conf` when the first arg is `rtpengine`.

### 4.1 Minimal standalone

```bash
docker run --rm -it --name rtpengine \
  --network host \
  -v rtpengine-rec:/rec \
  rtpengine:local
```

Baked-in defaults (`docker/rtpengine.conf`):

```ini
[rtpengine]
interface=public/MY_IP
foreground=true
log-stderr=true
listen-ng=MY_IP:22222
port-min=23000
port-max=32768
recording-dir=/rec
recording-method=pcap
recording-format=eth
listen-http=MY_IP:8080
```

### 4.2 Custom config (recommended)

```bash
mkdir -p ./run/conf ./run/rec
cat > ./run/conf/rtpengine.conf <<'EOF'
[rtpengine]
interface=internal/eth0
foreground=true
log-stderr=true
log-level=6
listen-ng=0.0.0.0:22222
port-min=23000
port-max=32768
recording-dir=/rec
recording-method=pcap
recording-format=eth
delete-delay=0
EOF

docker run --rm -d --name rtpengine \
  --network host \
  -v "$(pwd)/run/rec:/rec" \
  -v "$(pwd)/run/conf/rtpengine.conf:/home/rtpengine/rtpengine.conf:ro" \
  rtpengine:local
```

### 4.3 Extra CLI flags

```bash
docker run --rm --network host -v rtpengine-rec:/rec \
  rtpengine:local rtpengine --log-level=7
```

---

## 5. Run rtpengine-recording (lifecycle notify)

Recording does **not** start by default. Override the entrypoint.

### 5.1 Sample recording config (lifecycle)

```bash
mkdir -p ./run/conf ./run/rec ./run/out
cat > ./run/conf/rtpengine-recording.conf <<'EOF'
[rtpengine-recording]
foreground = true
log-stderr = true
log-level = 7
table = 0

# Must match rtpengine recording-dir
spool-dir = /rec
output-dir = /out
output-storage = file
output-format = wav
output-mixed = true
output-single = true
output-pattern = %c-%t-%r

### ---- Lifecycle HTTP notifications ----
notify-uri = http://host.docker.internal:9090/recording/notify
# full set, or a CSV subset (default is finished only)
notify-events = all
notify-json = true
notify-post = true
# notify-no-verify = true
# notify-no-metadata = true
notify-concurrency = 5
notify-retries = 10
notify-queue-limit = 1000
# notify-command = /usr/local/bin/rec-hook.sh
# notify-command-format = extended
EOF
```

### 5.2 Start recording daemon

```bash
docker run --rm -d --name rtpengine-recording \
  --network host \
  -v "$(pwd)/run/rec:/rec" \
  -v "$(pwd)/run/out:/out" \
  -v "$(pwd)/run/conf/rtpengine-recording.conf:/etc/rtpengine-recording.conf:ro" \
  --entrypoint rtpengine-recording \
  rtpengine:local \
  --config-file=/etc/rtpengine-recording.conf
```

CLI-only variant:

```bash
docker run --rm -d --name rtpengine-recording \
  --network host \
  -v "$(pwd)/run/rec:/rec" \
  -v "$(pwd)/run/out:/out" \
  --entrypoint rtpengine-recording \
  rtpengine:local \
  --foreground --log-stderr --log-level=7 \
  --spool-dir=/rec --output-dir=/out \
  --output-storage=file --output-mixed=true \
  --notify-uri=http://host.docker.internal:9090/recording/notify \
  --notify-events=all --notify-json --notify-post
```

### 5.3 docker-compose (both services)

```yaml
# docker-compose.rtpengine.yml
services:
  rtpengine:
    image: rtpengine:local
    network_mode: host
    volumes:
      - ./run/rec:/rec
      - ./run/conf/rtpengine.conf:/home/rtpengine/rtpengine.conf:ro
    restart: unless-stopped

  rtpengine-recording:
    image: rtpengine:local
    network_mode: host
    entrypoint: ["rtpengine-recording"]
    command: ["--config-file=/etc/rtpengine-recording.conf"]
    volumes:
      - ./run/rec:/rec
      - ./run/out:/out
      - ./run/conf/rtpengine-recording.conf:/etc/rtpengine-recording.conf:ro
    depends_on:
      - rtpengine
    restart: unless-stopped
```

```bash
docker compose -f docker-compose.rtpengine.yml up -d
docker compose -f docker-compose.rtpengine.yml logs -f rtpengine-recording
```

---

## 6. Recording lifecycle events

### 6.1 Enable / select events

| Config | Meaning |
|--------|---------|
| `notify-uri = URL` | Enable HTTP(S) notifications |
| `notify-events = finished` | **Default** — historical behaviour only |
| `notify-events = all` | Every token below |
| CSV subset | e.g. `opened,started,finished,failed,call-started,call-finished` |

| Token | Event name | When |
|-------|------------|------|
| `opened` | `recording_file_opened` | Output file created, header written |
| `started` | `recording_started` | First media packet written |
| `finished` | `recording_finished` | Successful close of non-empty recording |
| `discarded` | `recording_discarded` | Closed empty / discard flag |
| `failed` | `recording_failed` | Open/configure failure |
| `call-started` | `call_recording_started` | First mix/single output armed |
| `call-finished` | `call_recording_finished` | Call metafile torn down (success) |
| `call-discarded` | `call_recording_discarded` | Call torn down with discard |
| `all` | (all of the above) | Convenience alias |

Best-effort order: `call-started` → stream `opened` → `started` → terminal
(`finished`/`discarded`/`failed`) → `call-finished`/`call-discarded`.
Delivery is async with retries; notify failures **never** abort media I/O.

### 6.2 HTTP headers (always)

Prefix: `X-Recording-`

| Header | Content |
|--------|---------|
| `X-Recording-Event` | e.g. `recording_file_opened` |
| `X-Recording-Status` | short status: `opened`, `started`, `finished`, … |
| `X-Recording-Event-Time` | unix epoch (float seconds) |
| `X-Recording-Output-Id` | correlates open/start/finish for one stream |
| `X-Recording-Call-ID` | call id (typical) |
| file name / path headers | when applicable |

Terminal extras (`finished` / `discarded` / `failed`):

- `X-Recording-Duration-MS`, `X-Recording-File-Size`
- `X-Recording-Sample-Rate`, `X-Recording-Channels`
- `X-Recording-Call-End-Time`, `X-Recording-Stream-End-Time`
- `X-Recording-Error-Code`, `X-Recording-Error-Message` (failures)

### 6.3 JSON body (`notify-json = true`)

Forces **POST**. Typical fields: `event`, `event_time`, `status`, `call_id`,
`kind`, file names, `output_id`, `db`, times, media, `tag`, `metadata`, `error`.

```json
{
  "event": "recording_finished",
  "status": "finished",
  "event_time": 1720000000.12,
  "call_id": "abc-123@example.com",
  "output_id": "...",
  "kind": "mixed"
}
```

### 6.4 Related notify options

| Option | Default | Notes |
|--------|---------|-------|
| `notify-post` | false | Use POST (empty body unless json/attach) |
| `notify-json` | false | JSON body + force POST |
| `notify-no-verify` | false | Skip TLS verify (dev only) |
| `notify-no-metadata` | false | Omit call metadata strings |
| `notify-concurrency` | impl default | Max parallel HTTP requests |
| `notify-retries` | 10 | Exponential back-off from ~5s |
| `notify-queue-limit` | 1000 | Max in-flight **non-terminal** events; `0` = unlimited. **Terminal events are never dropped** |
| `notify-command` | unset | Optional external command hook |
| `notify-command-format` | `legacy` | `legacy` / `extended` / `json-env` |
| `notify-record` / `output-storage=notify` | off | Attach finished file to POST (not with JSON) |
| `notify-purge` | false | Disable default file storage when notify output enabled; purge after successful finished notify |

`notify-record` / `notify-purge` apply **only** to **finished** events.

### 6.5 Local webhook for testing

```bash
python3 - <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        print("HEADERS:", dict(self.headers), flush=True)
        print("BODY:", body.decode(), flush=True)
        self.send_response(204); self.end_headers()
    def do_GET(self):
        self.send_response(204); self.end_headers()
HTTPServer(("0.0.0.0", 9090), H).serve_forever()
PY
```

Point `notify-uri` at `http://host.docker.internal:9090/` (Docker Desktop) or
your host LAN IP.

### 6.6 Trigger a recording

From Kamailio / ng-client, start a call with recording enabled. Once media flows:

1. spool files appear under `/rec`
2. decoded wav/mp3 under `/out`
3. lifecycle POSTs hit your webhook

---

## 7. Storage backends (recording)

`output-storage` accepts multi values (CSV / repeated):

| Value | Behaviour |
|-------|-----------|
| `file` | Write under `output-dir` (default) |
| `db` | MySQL BLOB (`mysql-*` options) |
| `memory` | Keep media in RAM until finish |
| `notify` | Attach finished file on notify POST |
| `s3` | S3-compatible (`s3-host`, keys, region, ...) |
| `gcs` | Google Cloud Storage (`gcs-uri`, key or SA file) |
| `none` | Forward-only / notify-only patterns |

Example S3 + lifecycle:

```ini
output-storage = s3,file
s3-host = examplebucket.s3.amazonaws.com
s3-access-key = AKIA...
s3-secret-key = ...
s3-region = us-east-1
s3-path =
notify-uri = https://api.example.com/rec/hooks
notify-events = opened,started,finished,failed,call-finished
notify-json = true
```

---

## 8. Ports and volumes

| Item | Default / image | Purpose |
|------|-----------------|---------|
| NG control | `22222` | Kamailio <-> rtpengine |
| RTP range | UDP `23000-32768` (image exposes up to 65535) | Media |
| HTTP (optional) | `8080` | rtpengine HTTP interface |
| Volume `/rec` | shared | `recording-dir` <-> `spool-dir` |
| Volume `/out` | recording only | decoded media (`output-dir`) |
| Config mount | custom | override baked `rtpengine.conf` |

---

## 9. Integration with `cl/local-setup`

```bash
export RTPENGINE_IMAGE=rtpengine:local
cd /path/to/cl/local-setup
docker compose up -d rtpengine
# add/override a recording service using the same image + entrypoint rtpengine-recording
```

Mount a recording conf with `notify-events=all` and your webhook URL.

---

## 10. Logs and debugging

```bash
docker logs -f rtpengine
docker logs -f rtpengine-recording

docker run --rm -it --entrypoint /bin/bash rtpengine:local
ls -la /usr/local/bin/rtpengine*
```

Useful recording flags: `--foreground --log-stderr --log-level=7`.

Spool path **must** support **inotify** (normal Docker volumes/bind mounts OK;
some network FS are not).

---

## 11. Build scripts reference

| Script | Purpose |
|--------|---------|
| `build-linux-image.sh` | Preferred: full Debian image from current checkout |
| `docker-build-binaries.sh` | Build + extract ELF binaries to `./mac-binaries/` |
| `rebase-onto-master.sh` | Rebase current branch onto `origin/master` |
| `rebase-and-build.sh` | Rebase, then extract binaries |

```bash
OUT_DIR=./dist ./build-tools/docker-build-binaries.sh
BASE_REF=origin/master ./build-tools/rebase-onto-master.sh
```

Logs: `./build-tools/logs/`.

---

## 12. Notes / limitations

1. Image is **GNU/Linux**, not native macOS — run via Docker (or copy binaries
   to a matching Linux aarch64/amd64 host).
2. Default `CMD` is **rtpengine only** — always start recording explicitly.
3. `recording-dir` and `spool-dir` **must be the same path**.
4. Lifecycle notify is best-effort/async; terminal events are prioritised over
   the non-terminal queue limit.
5. File attach (`output-storage=notify` / `notify-record`) is for **finished**
   only and is not combined with a JSON body.
6. Upstream details: `docs/rtpengine-recording.md`, sample conf
   `etc/rtpengine-recording.conf`.

---

## 13. Cleanup

```bash
docker rm -f rtpengine rtpengine-recording 2>/dev/null || true
docker image rm rtpengine:local rtpengine-recording-notify:local 2>/dev/null || true
rm -rf ./run ./mac-binaries ./build-tools/logs
```

---

## 12.5.1.31 rich logs — one bin dir per OS

See `build-tools/BINS.md`. Canonical dirs only:

| OS | Directory |
|----|-----------|
| Debian siprec | `release-bins/12.5.1.31-rich-logs/debian/` |
| RHEL 8 lab | `release-bins/12.5.1.31-rich-logs/rhel/` |

| Artifact | How |
|----------|-----|
| Debian userspace bins | `./build-tools/docker-build-binaries.sh` → `release-bins/.../debian/` |
| RHEL8 bins | `./build-tools/docker-build-rhel-binaries.sh` → `release-bins/.../rhel/` |
| Deploy tarball | `./build-tools/package-rich-logs-tarball.sh` → `rtpengine-12.5.1.31-rich-logs-<UTC YYYYMMDDHHMMSS>.tar.gz` |
| Optional debian staging | `python3 build-tools/package-debian-bins.py` (copies from the debian dir above) |

Do **not** recreate `rhel-binaries/`, `rhel-binaries-12.5.1.31/`, or `rhel/bins/`.

### Side-by-side (does NOT stop production)

    cd ~/rtpengine
    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/side-by-side-test/run-test.sh install-units
    # RHEL lab:
    # BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/rhel" sudo -E bash ...
    sudo bash build-tools/side-by-side-test/run-test.sh start
    sudo bash build-tools/side-by-side-test/run-test.sh smoke
    sudo bash build-tools/side-by-side-test/run-test.sh stop
    sudo bash build-tools/side-by-side-test/run-test.sh uninstall-units

Isolation: NG 127.0.0.1:23222, table 44, spool /var/spool/recording-test-12.5,
units rtpengine-test / rtpengine-recording-test.

### Promote after smoke

    BIN_DIR="$PWD/release-bins/12.5.1.31-rich-logs/debian" \
      sudo -E bash build-tools/install-on-debian-siprec-userspace.sh promote

Installer ALWAYS backs up current bins + configs to
/var/backups/rtpengine-rich-logs/<timestamp>/ before stop/replace.
