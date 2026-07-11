# kindled

Rust sync daemon for the Kindle side of the private cloud. One static
ARMv7 binary (~1 MB), no runtime, HTTPS via rustls with bundled Mozilla
roots (the Kindle's own CA store never matters). Replaces the
`privatecloud/kindle-agent.sh` prototype.

## What it does

Every poll (default 300 s), one reconciliation pass:

1. Fetch `/api/v1/manifest` from the Folio server (`X-Api-Token` auth).
   The manifest lists only the books queued for this device ("Send to
   Kindle" in the web UI) — never the whole library.
2. Download new/changed books into `/mnt/us/documents/PrivateCloud`:
   stream to `.part`, verify SHA-256, atomic rename, then trigger
   `com.lab126.scanner reScanFile` + `com.lab126.ccat triggerUpdate` so the
   stock Library picks the file up (the capture-proven ingestion path).
3. Sync reading state: the newest `.sdr` sidecar content wins across
   devices. Local changes are tar.gz'd and PUT to the server; newer server
   bundles are restored locally after backing up the existing sidecar to
   `<book>.sdr.bak-<timestamp>`. Restored files get the server-side mtime
   so they never bounce back as fresh changes.
4. Process `removals[]` (manifest v3): push any newer reading state, delete
   the book + sidecar (+ installed thumbnail), drop the catalog row, then
   ack so the server closes the delivery. This is how Folio's low-space
   eviction frees the Kindle.
5. Upload `My Clippings.txt` when its mtime moved — Folio parses
   highlights/notes out of it (the sidecars only carry positions).
6. POST `/api/v1/device/status`: free/total bytes (statvfs on the
   documents dir), battery (`powerd battLevel`), firmware, serial, the
   pass report, and the list of books actually on disk (the server
   reconciles deliveries against it and plans evictions).

Replacement downloads (server sha changed) delete the old file and let the
scanner drop the row *before* the new bytes land — verified on 5.19.2 that
an in-place overwrite keeps stale catalog metadata. The `.sdr` sidecar
survives the swap, so the reading position does too.

State lives in `/mnt/us/privatecloud/state.json` (atomic writes — the
Kindle loses power whenever it likes).

## Commands

```sh
kindled init http://192.168.1.75:3000 <device-token>   # writes config, checks /healthz
kindled sync      # one pass
kindled daemon    # loop every POLL_INTERVAL seconds
kindled list      # print server manifest
kindled status    # config, tracked books, server health
```

The device token comes from the Folio web UI (Devices page).

## Config

`/mnt/us/privatecloud/config` — same KEY=VALUE file the shell agent used:

```sh
SERVER_URL=http://192.168.1.75:3000
API_TOKEN=...
DOCUMENT_DIR=/mnt/us/documents/PrivateCloud
POLL_INTERVAL=300
AUTO_DOWNLOAD=1     # 0 = mirror nothing automatically
THUMBNAIL_DIR=/mnt/us/system/thumbnails       # firmware cover cache
CLIPPINGS_PATH=/mnt/us/documents/My Clippings.txt
```

`PRIVATECLOUD_DIR` overrides the base directory (used by tests/dev).

## Build & install

```sh
./build-kindle.sh   # docker (rust-musl-cross image); rustup fallback
scp target/armv7-unknown-linux-musleabihf/release/kindled root@KINDLE:/mnt/us/privatecloud/
```

HTTPS comes from rustls (`minreq/https-rustls`) with webpki bundled
roots. rustls' `ring` backend contains C/asm, so cross-builds run inside
the `messense/rust-musl-cross:armv7-musleabihf` docker image, which
carries the ARM musl C toolchain; everything else stays pure Rust and
the binary stays fully static.

## KUAL

`kual/` is a KUAL extension with menu entries for sync-now,
start/stop background sync, and a manual library refresh:

```sh
scp -r kual root@KINDLE:/mnt/us/extensions/folio
```

Logs land in `/mnt/us/privatecloud/kindled.log`.

## Verified

- `cargo test` — 11 unit tests (config parsing, state roundtrip, sdr
  pack/unpack with backup, manifest parsing, download decisions).
- Two simulated devices against the live Rails server: 6 books mirrored
  with checksum verification; reading progress written on device A
  arrived on device B; repeated syncs converge to a clean no-op; a
  corrupt reading-state bundle is rejected without touching local state.
