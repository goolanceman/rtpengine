# Fix: "Call recording through /proc interface requested, but kernel table not open"

Host context for this write-up: **RHEL 8.10**, branch `rich-recording-debug-logs`,
proc-only recording with `table=42` and systemd units under `/etc/systemd/system/`.

## Symptom

```text
WARNING: Call recording through /proc interface requested, but kernel table not open
```

Seen with `--recording-method=proc` when `record-call=yes`. Recording meta/start
logs may still appear, but:

- No usable kernel call index (`kernel.is_open == false`)
- No `/proc/rtpengine/<table>/calls/...` streams for `rtpengine-recording`
- Proc recording does not capture RTP

Often paired at startup with:

```text
ERR: FAILED TO OPEN KERNEL TABLE 42 (No such file or directory), KERNEL FORWARDING DISABLED
```

or:

```text
CRIT: Fatal error: Kernel module version mismatch or other fatal error
```

## Why it happens (recommended model)

Docs / design for **proc** recording:

1. Load kernel module (`nft_rtpengine` and/or `xt_RTPENGINE`) → `/proc/rtpengine/`.
2. rtpengine starts with **same** `--table=N` as recording-daemon `table = N`.
3. Userspace must **open** `/proc/rtpengine/N/control` (`kernel.is_open`).
4. rtpengine writes **`.meta` into `--recording-dir`** (spool); packet data is exposed under
   `/proc/rtpengine/N/calls/...`.
5. `rtpengine-recording` watches the same path as `--spool-dir` and reads those proc streams.

Proc is **not** pcap. Without an open kernel table, the warn path in
`daemon/recording.c` (`proc_init`) fires and no streams are published.

On this host two concrete failures stacked:

| # | Failure | Effect |
|---|---------|--------|
| 1 | Userspace binary **newer** than installed `.ko` | `Kernel module version mismatch` → daemon cannot use module cleanly |
| 2 | nftables path deleted table 42 then did not leave `/proc/rtpengine/42` open | `FAILED TO OPEN KERNEL TABLE 42` → `kernel.is_open` false → warn on every record |

Modern code prefers creating the table via **nftables CREAT** expressions.
`kernel_create_table("add N")` (write to `/proc/rtpengine/control`) runs mainly on
the **`--xtables`** path. On this host, nft chains alone did not leave a working
`/proc/rtpengine/42/control` for userspace open.

## Fix steps (what we did)

### 1. Confirm module and table

```bash
uname -r
lsmod | grep -i rtp
ls -la /proc/rtpengine/
# Optional manual create (daemon usually owns this):
echo "add 42" | sudo tee /proc/rtpengine/control
ls -la /proc/rtpengine/42/
```

### 2. Build matching kernel module from **this** checkout

Userspace and module ABI must match the same git tree.

```bash
cd /path/to/rtpengine/kernel-module
make clean && make
# produces nft_rtpengine.ko
```

### 3. Replace installed module (unload old first)

Old module often has **refcount > 0** while nft jump rules / chains exist.

```bash
sudo systemctl stop rtpengine rtpengine-recording

# Remove nft jumps/chains that reference rtpengine (handles from nft -a list ...)
# Example pattern (adjust handles/families for your host):
sudo nft -a list chain ip filter INPUT   # find "jump rtpengine_42" handle
sudo nft delete rule ip filter INPUT handle <H>
# same for ip6 FORWARD/INPUT as needed
sudo nft flush chain ip filter rtpengine_42 2>/dev/null || true
sudo nft delete chain ip filter rtpengine_42 2>/dev/null || true
# repeat for ip6

echo "del 42" | sudo tee /proc/rtpengine/control 2>/dev/null || true
sudo rmmod nft_rtpengine   # must succeed; fix leftover nft if "in use"
sudo rmmod xt_RTPENGINE 2>/dev/null || true

sudo cp -a kernel-module/nft_rtpengine.ko \
  /lib/modules/$(uname -r)/updates/nft_rtpengine.ko
sudo depmod -a
sudo modprobe nft_rtpengine

# Verify NEW module is loaded (srcversion must match file)
cat /sys/module/nft_rtpengine/srcversion
modinfo -F srcversion nft_rtpengine
# both strings identical
```

### 4. Proc-only runtime flags (recommended on this host)

**rtpengine** (via `/usr/local/libexec/rtpengine-start.sh`):

- `--table=42`
- `--recording-method=proc`
- `--recording-dir=/var/spool/recording`
- `--xtables` — forces `kernel_create_table(42)` so `/proc/rtpengine/42` exists
- Matching userspace binary under `LD_LIBRARY_PATH=/usr/local/lib`

**rtpengine-recording** (`/etc/rtpengine-recording.ini`):

```ini
table = 42
spool-dir = /var/spool/recording
log-level = 5
output-dir = /tmp/recordings   # must differ from spool-dir
```

Do **not** point `output-dir` at the same directory as `spool-dir`.

### 5. systemd drop-ins used

- `/etc/systemd/system/rtpengine.service.d/20-rhel-local.conf`  
  - `ExecStart=/bin/bash /usr/local/libexec/rtpengine-start.sh`  
  - `LD_LIBRARY_PATH=/usr/local/lib`  
  - Pre: `modprobe nft_rtpengine`  
  - Avoid RR/`SETSCHEDULER` failures on this host (`CPUSchedulingPolicy=other`)

- `/etc/systemd/system/rtpengine-recording.service.d/20-rhel-local.conf`  
  - foreground start + same `LD_LIBRARY_PATH`

```bash
sudo systemctl daemon-reload
sudo systemctl restart rtpengine-recording
sudo systemctl restart rtpengine
```

### 6. Verify success

```bash
systemctl is-active rtpengine rtpengine-recording
ls -la /proc/rtpengine/42/control   # must exist while daemon runs
# Offer with record-call=yes, then:
sudo journalctl -u rtpengine -n 50 --no-pager | grep -E 'proc recording|kernel table not open'
```

**Good:**

```text
proc recording init: ... kernel_call_idx=0 proc_meta=/var/spool/recording/....meta
recording start: ... method=proc ...
```

**Bad (fixed when gone):**

```text
Call recording through /proc interface requested, but kernel table not open
```

Also expect recording-daemon:

```text
stream open: ... full_path=/proc/rtpengine/42/calls/<parent>/...
recording lifecycle: event=started ...
```

## After reboot

```bash
sudo modprobe nft_rtpengine
# confirm srcversion still matches deployed .ko
sudo systemctl start rtpengine rtpengine-recording
ls /proc/rtpengine/42
```

Optional: enable units + a small oneshot that only runs `modprobe nft_rtpengine`
before `rtpengine.service`.

## Related host pitfalls

1. **Module/userspace mismatch** after every userspace upgrade → rebuild/install `.ko` from same commit.
2. **Cannot rmmod** → leftover nft `jump rtpengine_*` or `/proc/rtpengine/N` table; delete rules/chains, `echo del N > control`, then rmmod.
3. **docker rtpengine / rtpengine-native** fighting for NG `:22222` → stop/disable the conflict.
4. **pcap vs proc**: unit must use `proc` for recording-daemon stream path; pcap alone will not drive `/proc/.../calls`.

## Quick reference paths (this host)

| Piece | Path |
|-------|------|
| Userspace | `/usr/local/bin/rtpengine` |
| Recording daemon | `/usr/bin/rtpengine-recording` |
| Bundled libs | `/usr/local/lib` |
| Start script | `/usr/local/libexec/rtpengine-start.sh` |
| Module | `/lib/modules/$(uname -r)/updates/nft_rtpengine.ko` |
| Kernel tree build | `kernel-module/` in this repo |
| Spool | `/var/spool/recording` |
