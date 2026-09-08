# Kindle Private Cloud

A privacy-preserving, self-hosted library for a jailbroken Kindle.

The design (validated by the capture research in `observer/`) avoids
pretending to be Amazon's backend. A private server publishes a manifest
and book files; a Kindle-side daemon downloads them into
`/mnt/us/documents/PrivateCloud`, where the stock scanner/catalog indexes
them into the normal Library UI. Reading progress syncs between Kindles
through `.sdr` sidecar bundles on the private server, not WhisperSync.

## Components

- **`server/` — Folio, the backend + web UI** (Rails 8, SQLite only).
  Multi-format library with Calibre-powered conversion (auto-AZW3 so
  everything is Kindle-deliverable), FTS5 full-text search with snippet
  highlighting, and a phone-first, installable web UI with live-updating
  pages (Turbo morph over solid_cable). Per-device send queue with a
  low-space eviction planner (finished / never-opened / dormant books are
  suggested — or auto-queued — for removal when storage runs short),
  device pages with telemetry and sync history, highlights & notes
  imported from My Clippings.txt, and delivery preparation that makes the
  Kindle show real covers (see below). Exposes the token-authenticated
  device API the daemon consumes.
- **`kindled/` — the Kindle daemon** (Rust, single static ARMv7 binary,
  ~1 MB). Mirrors the manifest with SHA-256 verification and atomic
  writes, performs server-requested removals with an ack handshake,
  reports device status (statvfs/battery/firmware plus the on-disk book
  list), uploads My Clippings.txt, triggers the LIPC ingestion hooks
  (pre- and post-5.19 property sets), and syncs reading state
  latest-mtime-wins with local backups. Ships with a KUAL extension.

  Cover fix, verified live on firmware 5.19.2 (all three conditions are
  required):
  1. No store ASIN — calibre files carry `EXTH 501=EBOK` + a uuid ASIN,
     so the firmware asks Amazon for the cover (never resolves), caches a
     "no image available" placeholder, and never extracts the embedded
     cover. The prepared copy neutralizes the ASIN records (112/113/504).
  2. An explicit `PDOC` cdeType — with 501 missing entirely the scanner
     leaves AZW3 rows typeless and the UI renders text tiles, so 501 is
     rewritten in place (EBOK→PDOC), in *both* EXTH copies of a joint
     file.
  3. A MOBI6 container — the 5.19 Library UI never renders cover art for
     KF8-only AZW3 (`x-mobi8-ebook`), even with a perfect extracted
     thumbnail. AZW3 sources are transcoded to joint MOBI6+KF8 files
     (`--mobi-file-type both`): the reader opens the KF8 half, the UI
     sees a MOBI6 book and shows the cover.
- **`observer/` — research tooling.** Read-only SSH capture scripts and
  the findings that shaped the design (see its README).
- **`privatecloud/` — first prototypes** (Python manifest server, shell
  agent, catalog-row experiments). Superseded by `server/` + `kindled/`,
  kept for reference; the raw remote-row injection path remains
  intentionally unsupported (tapping such rows crashes KPP — see the
  research notes).

## Prerequisites

- Ruby 3.3.6, Bundler
- Calibre CLI (`ebook-convert`, `ebook-meta`)
- libvips
- SQLite
- Docker or rustup (to build kindled)
- A jailbroken Kindle with SSH and KUAL

See `server/README.md` and `kindled/README.md` for component-specific
setup.

## Quick start

```sh
# Server (listens on localhost)
cd server
bundle install
bin/rails db:prepare db:schema:load:queue db:seed   # prints login + device token
bin/rails server

# Kindle daemon
cd kindled
./build-kindle.sh
scp target/armv7-unknown-linux-musleabihf/release/kindled root@KINDLE:/mnt/us/privatecloud/
ssh root@KINDLE /mnt/us/privatecloud/kindled init http://SERVER_IP:3000 DEVICE_TOKEN
ssh root@KINDLE /mnt/us/privatecloud/kindled sync
```

Pass `-b 0.0.0.0` to `bin/rails server` only on a trusted LAN so other
devices on that network can reach it.

Add books from your phone at `http://SERVER_IP:3000` (installable PWA).

## Architecture rationale

Rails for the backend, Rust on the device. All heavy ebook work
(conversion, metadata, covers, text extraction) shells out to Calibre in
either language, so the backend is orchestration + search + a good web
UI — Rails 8 with SQLite covers that with zero external services. The
Kindle has no runtime to spare, so the daemon is a dependency-free
static Rust binary.

## Repository Hygiene

Raw captures, temporary Kindle databases, copied certificates, and copied
Kindle binaries are ignored. They may contain account/device information
or proprietary Amazon material and should stay local unless they are
manually redacted first.

## Security

The trust model is a private network, not the public internet. The
kindled↔server device API and the legacy `privatecloud/` prototype speak
plain HTTP with bearer tokens, so deploy them only on a trusted LAN or
over WireGuard/Tailscale — never exposed to the internet. The web UI
itself should be served over HTTPS (Rails `force_ssl` is on in
production; put a TLS-terminating reverse proxy in front of it). Note
that `privatecloud/` is a set of legacy prototypes kept for reference,
not a supported deployment path. See `SECURITY.md` for how to report
vulnerabilities.

## License

AGPLv3 — see `LICENSE`. The server component is network software, so the
Affero clause applies: if you run a modified Folio instance for others,
you must offer them its source.

### Third-party

The in-browser reader vendors foliate-js (MIT), pdf.js (Apache-2.0),
and reader fonts (SIL OFL). Copies of those licenses live under
`server/public/reader/`; this file does not restate them.

## Safe Direction

1. Keep private content as local/sideloaded files from the Kindle's point
   of view.
2. Use the daemon for manifest sync, downloads, checksum verification,
   scanner refresh, and progress sidecar sync.
3. Block Amazon sync/upload paths only after mapping them precisely.
4. Revisit KPP/KSDK hooks later only if exact stock remote
   tap-to-download is still worth the firmware-specific risk.
