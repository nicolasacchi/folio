# Kindle Private Cloud Prototype

This is the first safe implementation path: use a self-hosted server for files
and a small Kindle-side agent to download books into the normal local documents
folder. The stock scanner/catalog services then make the books appear in the
existing Kindle Library.

It does not yet intercept tapping a fake archived Library row. The capture in
`observer/captures/action-20260709-152818-fake-remote-catalog-tap` showed that
catalog rows alone are not enough because KPP reports `No download entry found`.

## Server

Put supported files in a host directory, then run:

```sh
python3 privatecloud/server.py --books /path/to/books --host 0.0.0.0 --port 8765
```

Endpoints:

- `/manifest.json`
- `/manifest.tsv`
- `/books/<relative-path>`
- `/healthz`

The filename format `Title -- Author.ext` or `Title - Author.ext` is used to
populate display metadata in the manifest.

## Kindle Agent

Copy `kindle-agent.sh` to the Kindle, initialize it with the server URL, then
sync/list/download:

```sh
sh /mnt/us/privatecloud/kindle-agent.sh init http://HOST_IP:8765
sh /mnt/us/privatecloud/kindle-agent.sh sync
sh /mnt/us/privatecloud/kindle-agent.sh list
sh /mnt/us/privatecloud/kindle-agent.sh download BOOK_ID
```

Downloaded files go to `/mnt/us/documents/PrivateCloud`. After each download the
agent calls:

- `com.lab126.scanner reScanFile`
- `com.lab126.ccat triggerUpdate`

Those are the same local refresh paths observed during the sideload capture.

## Daemon Language Recommendation

Use Rust for the long-lived Kindle daemon, but keep shell for installation,
KUAL menu entry points, and simple recovery commands.

Why Rust fits this Kindle:

- It can produce one small static ARMv7 binary, so the Kindle does not need a
  Python/Node/runtime stack.
- It is reliable for a daemon that watches files, writes state atomically,
  downloads books, verifies checksums, and recovers after interrupted writes.
- It can call existing Kindle tools such as `lipc-set-prop` when direct LIPC
  bindings are not worth the complexity.
- It avoids the memory and dependency cost of Go/Node/Python on this device.

Keep the first daemon deliberately narrow:

1. Read `/mnt/us/privatecloud/config`.
2. Poll the server manifest.
3. Maintain a local state file under `/mnt/us/privatecloud`.
4. Download selected books into `/mnt/us/documents/PrivateCloud`.
5. Verify SHA-256 before publishing the file.
6. Trigger scanner/catalog refresh.
7. Poll `.sdr` sidecar folders and sync progress state.

Shell remains useful as the compatibility layer around KUAL and for commands
that are already proven on-device. The shell agent in this directory is still
the right prototype until the protocol and state model settle.

## Cross-Kindle Progress Sync

For private books, sync reading position through the local sidecar files rather
than through Amazon WhisperSync.

Model:

1. The server manifest assigns each book a stable private `id`.
2. Kindle A downloads the book and reads it normally.
3. The Kindle reader updates `/mnt/us/documents/PrivateCloud/<book>.sdr/`.
4. The daemon detects changes to files such as `.mbp1` and `.mbs`.
5. The daemon uploads a small sidecar bundle to the private server under that
   book id and device/profile id.
6. Kindle B downloads the same book.
7. Before opening the book, Kindle B downloads the latest sidecar bundle,
   backs up any local sidecar, restores the server copy, and triggers a local
   refresh if needed.

The first conflict policy should be simple: latest modified sidecar wins, with
local backups before overwrite. Later the server can keep per-device versions
and ask for manual conflict resolution if two Kindles read the same book
offline.

## Verified Smoke Test

On 2026-07-09 this was tested end-to-end with the fixture server at
`http://SERVER_IP:8765`:

1. Kindle fetched `/healthz`.
2. Kindle agent synced `/manifest.tsv`.
3. Kindle agent listed one fixture item.
4. Kindle agent downloaded it into `/mnt/us/documents/PrivateCloud`.
5. The Kindle created a normal `.sdr` sidecar.
6. `/var/local/cc.db` showed the file as a visible local Library entry.

This proves the private content-delivery path works. The remaining hard part is
making a not-yet-downloaded private item appear as a remote/searchable stock
Library row and intercepting its tap action cleanly.

## Catalog Row Warning

`catalog_import.py` and `deploy-catalog-test.sh` are experiment tools. A
remote-only private row appears in the stock Library, but tapping it currently
triggers Kindle's fatal application dialog because KPP reports
`KSDKLibraryDownloadState: No download entry found`.

The follow-up `deploy-ksdk-catalog-test.sh` experiment also added a matching
`ksdk.asset.db` node. Tapping still triggered the fatal dialog. Do not use raw
private archived rows as the final UX. Use them only to study search/visibility,
then restore the backup with:

```sh
sh privatecloud/restore-catalog-test.sh /mnt/us/selfhost-catalog-backups/<stamp>
```

Both raw-row deploy scripts require `CONFIRM_REMOTE_ROW_TEST=1` to run.
