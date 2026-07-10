# Kindle Observer

Small read-only helpers for mapping a jailbroken Kindle over SSH.

The default target is the KOReader Dropbear server on `root@192.168.1.95`.
Override it with:

```sh
KINDLE_HOST=root@192.168.1.95 KINDLE_SSH_OPTS="-F /dev/null" observer/scripts/collect.sh
```

The capture output goes under `observer/captures/`.

Current device notes:

- Firmware: Kindle 5.19.2
- Kernel: Linux 4.9.77-lab126, ARMv7
- Root filesystem: read-only ext3
- Writable persistent state: `/var/local`
- Userstore: `/mnt/us`
- KOReader SSH authorized keys: `/mnt/us/koreader/settings/SSH/authorized_keys`
- Main modern UI process: `/app/bin/KPPMainApp`
- Legacy Java framework: `/usr/java/bin/cvm`
- Relevant services: `whisperstore`, `progressivedownloads`, `minerva_service`, `juno-acs-helper`, `logmgr`, `wifid`, `appmgrd`

The safe next loop is:

1. Run `observer/scripts/collect.sh`.
2. Trigger one Kindle action manually, such as opening Home, starting sync, downloading a personal document, or opening the store.
3. Run `observer/scripts/tail-observe.sh` in another terminal during that action.
4. Compare new log lines, LIPC changes, and network destinations.

Do not modify `/etc/upstart` or attach `strace` to `KPPMainApp` until recovery and restart behavior are understood.

## First Sync Capture

Capture: `observer/captures/action-20260709-144757-sync`

Manual Sync sequence observed:

1. Quick Actions emits the Sync UI metric from `KPP_HOME`.
2. `cvm` reports `QuickActionsLipcProvider` state changes and starts `WhisperSyncV2PaginateServiceImpl`.
3. `KPPMainApp` receives the sync event and queues profile/notebook sync handlers.
4. `todo` starts processing customer-triggered work.
5. `tmd` starts upload/download transfer IDs, receives HTTP 200 responses, and writes archive sync state.
6. Cover art refreshes are requested through KPP and fulfilled/fail through the legacy cover-art service.

Processes seen on external HTTPS connections during manual Sync:

- `KPPMainApp`: persistent KPP/Home/UI service traffic.
- `cvm`: legacy Java framework traffic, including archive/cover/sync-adjacent work.
- `todo`: customer-triggered work queue status.
- `tmd`: transfer manager upload/download work.
- `AdmDaemon`: additional Amazon device-management/service traffic.

Useful commands:

```sh
observer/scripts/action-capture.sh sync 90
observer/scripts/summarize-action.sh observer/captures/action-20260709-144757-sync
observer/scripts/summarize-download.sh observer/captures/action-20260709-145342-book-download
observer/scripts/summarize-local-add.sh observer/captures/action-20260709-150152-local-add-after-sync
observer/scripts/summarize-progress-sync.sh observer/captures/action-20260709-150633-progress-sync
observer/scripts/summarize-catalog.sh
observer/scripts/collect.sh
```

Current architectural read: replacing the visible interface does not require replacing one monolith. The interface is KPP, but manual sync still fans out into legacy services through LIPC and `todo`/`tmd`. A self-hosted replacement should start by implementing a local content/sync agent that integrates with `/mnt/us/documents`, `/var/local` metadata, and LIPC notifications, before attempting any endpoint redirection.

## Book Download Capture

Capture: `observer/captures/action-20260709-145342-book-download`

Observed cloud book download sequence:

1. `KPPMainApp` receives the library action `com.amazon.library.actions.download_book`.
2. KPP publishes a `KSDKLibraryDownloadState` event with content type `PDOC`.
3. `cvm` verifies the download and asks for a manifest download.
4. `tmd` downloads a small JSON manifest into `/mnt/us/documents/Downloads/Items01/*.tmp_manifest`.
5. `cvm` runs `ManifestDownloadPostProcessor` and invokes `KindleContentDownloadManagerApplication`.
6. `KindleContentDownloadManagerApplication` calls its `nontododownload` path, enqueues required assets, and asks `tmd` to download staged `.temp_content` files.
7. `tmd` downloads the main KFX asset as `application/x-kfx-ebook`. Optional sidecar assets may 404 and become deferred without blocking the required main asset.
8. The content manager replaces the staged asset, emits transfer status over LIPC, then `cvm` updates the catalog and index.
9. `ReaderSDKImpl` opens the book once the catalog/update path reaches the ready-to-open state.

The important local service contract is `com.amazon.kindlecontentdownloadmanager`, which exposes these LIPC properties:

- `download`
- `tododownload`
- `ondemand`
- `assetstatus`
- `active`
- `cancel`
- `preloadrequiredassets`
- `preloadnonrequiredassets`

Practical build direction:

1. First prototype a self-hosted side-channel: a server exposes a simple library manifest plus downloadable files, and a small Kindle agent downloads them into `/mnt/us/documents`.
2. After direct side-loading works reliably, add catalog refresh/LIPC notification handling so KPP's existing Library UI notices the new content quickly.
3. Only then research whether the stock cloud-download path can be fed by reproducing the local manifest/content-manager contract. That is more fragile because it touches `cvm`, `KindleContentDownloadManagerApplication`, `tmd`, staged file naming, and catalog post-processing.

## Local Add After Sync Capture

Capture: `observer/captures/action-20260709-150152-local-add-after-sync`

Test action: copied a small text document into `/mnt/us/documents`.

Observed local ingestion sequence:

1. `scanner` loaded the `.txt` extractor and `libfileE.so`.
2. `cvm` marked the item as local/non-cloud-indexable, then allowed indexing.
3. `com.lab126.ccat` emitted an `updated` LIPC event.
4. `KPPMainApp` received the platform database update and notified its composite repository.
5. KPP's Home/Library data provider emitted `OnAssetsUpdated`.
6. A normal Kindle sidecar directory appeared next to the file: `/mnt/us/documents/<name>.sdr`.

Useful local refresh services:

- `com.lab126.scanner`
  - `reScanFile` writes a string path to rescan one file.
  - `doFullScan` writes an integer to trigger a full scan.
  - `fullScanStatus` reads scan state.
- `com.lab126.ccat`
  - `triggerUpdate` writes an integer to emit/update the catalog event.
- `com.lab126.indexer`
  - `numberOfItemsToBeIndexed` reads pending index work.
  - `indexAndSearchContent` writes a string to index/search content.

This proves the lowest-risk replacement path: a Kindle-side agent can download supported, non-DRM local files from a self-hosted server into `/mnt/us/documents`, then call scanner/catalog LIPC hooks so the stock Library UI refreshes. That does not require endpoint redirection for the first prototype.

## Progress Sync Capture

Capture: `observer/captures/action-20260709-150633-progress-sync`

Test action: opened a downloaded book, read/changed position, then ran manual Sync.

Observed privacy-relevant sequence:

1. Opening the book starts `com.lab126.booklet.reader`; `ReaderSDKImpl` opens the content.
2. Reader loads local sidecar/annotation state and initializes the annotation cache.
3. KPP reader logs position range changes and queues a reading-progress annotation save.
4. For this KPP/CVM mode, KPP logs that Java/CVM handles reading-progress persistence automatically.
5. Reader metrics include content identity and reading span positions in local logs.
6. Manual Sync starts `WhisperSyncV2PaginateServiceImpl`.
7. `todo` processes `legacy.UPLOAD.MESG`, `legacy.UPLOAD.SNAP`, and `whispersync.upload`.
8. `tmd` performs upstream transfers during the sync window.

Architectural implication: Amazon sync is not only library/download metadata. Reading activity flows through reader state, annotation/sidecar handling, `whisperstore`/WhisperSync, `todo`, and `tmd`. A privacy-preserving replacement needs either:

1. keep books as local/sideloaded content and avoid Amazon sync for reading state, or
2. intercept/replace the WhisperSync-style progress path with a local service before allowing sync-like behavior.

Next comparison target: repeat the same progress-sync capture using a purely sideloaded local document, then compare whether `legacy.UPLOAD.*` or `whispersync.upload` carries book-specific progress or whether only generic sync/status traffic remains.

## Local Progress Sync Capture

Capture: `observer/captures/action-20260709-151241-local-progress-sync`

Test action: opened the sideloaded `selfhost-smoke-test.txt`, interacted with the reader, then ran manual Sync.

Observed sequence:

1. The text file opened through the normal reader path as a local `txt`/mobi-style document.
2. `ReaderInfoLog` reported the file as unencrypted, not a sample, and backed by local sidecar state.
3. The file was marked `CONTENT_NOT_CLOUD_INDEXABLE`.
4. The local sidecar changed: `.mbp1` grew and a `.mbs` sidecar appeared under `/mnt/us/documents/selfhost-smoke-test.sdr/`.
5. Manual Sync still initialized `BookReadStates`.
6. Manual Sync still processed `legacy.UPLOAD.MESG`, `legacy.UPLOAD.SNAP`, and `whispersync.upload`.
7. `tmd` still made upstream transfers during the sync window.

Conclusion: sideloading into `/mnt/us/documents` is enough to avoid Amazon content download, but it is not enough to guarantee reading privacy while the stock Amazon Sync path remains active. Even local content can still participate in read-state/sync machinery. The self-hosted replacement therefore needs a progress-sync strategy, not only a content-delivery strategy.

Practical privacy architecture:

1. Use the local content path for books.
2. Use a Kindle-side agent to watch/copy `.sdr` state and sync it to the custom server.
3. Block, disable, or replace Amazon WhisperSync/BookReadStates before allowing any user-facing "Sync" equivalent.
4. Later, optionally reproduce the stock Sync button behavior locally by invoking our agent and local scanner/catalog hooks instead of Amazon `todo`/`tmd` uploads.

## Private Cloud Library Target

Goal: show all books in the stock Kindle Library, searchable by title/author/metadata, with local on-demand download from a self-hosted server.

Observed catalog model:

- `/var/local/cc.db` is the main legacy/catalog database for Library rows.
- `cc.db Entries` has the fields needed for cloud-style availability:
  - `p_isArchived`
  - `p_isVisibleInHome`
  - `p_isDownloading`
  - `p_location`
  - `p_cdeKey`
  - `p_cdeType`
  - `p_mimeType`
  - title/author JSON fields
  - `p_metadataUnicodeWords`
  - indexing state fields
- Archived visible rows generally have `p_isArchived=1`, no local path, searchable metadata, and CDE identity.
- Downloaded/sideloaded rows have `p_isArchived=0` and a path-like `p_location`.
- `/var/local/ksdk.asset.db` and `/var/local/ksdk.content.db` mirror parts of the modern KSDK/KPP library model.
- `/mnt/us/system/Search Indexes/Index.db` is the full-text content index; Library title/author search is primarily driven by catalog metadata.

Likely implementation shape:

1. Server stores the private library manifest: stable book id, title, author, format, size, checksum, cover, tags/collections, and download URL.
2. Kindle catalog agent imports manifest rows as archived/remote catalog entries, with metadata populated for Library search.
3. Agent triggers catalog refresh through `com.lab126.ccat triggerUpdate` and KPP Library refresh actions.
4. When the user chooses a remote item, a download agent maps the requested book id to the self-hosted URL, downloads into `/mnt/us/documents`, then calls `com.lab126.scanner reScanFile` and `com.lab126.ccat triggerUpdate`.
5. The agent syncs `.sdr` reading state with the custom server and blocks/replaces Amazon WhisperSync uploads.

High-risk part: stock archived-item download normally expects Amazon manifest/content-manager behavior. For a private server we should first test a reversible fake archived item with full DB backups, then decide whether to:

1. inject catalog rows and intercept the download action locally, or
2. build a small KUAL/KPP-adjacent "download from private library" action while keeping stock Library search/visibility.

## Fake Remote Catalog Row Test

Capture: `observer/captures/action-20260709-152818-fake-remote-catalog-tap`

Test action: inserted a reversible fake archived `cc.db Entries` row with private test metadata, no local path, `p_isArchived=1`, `p_isVisibleInHome=1`, and a synthetic CDE key. The live catalog was backed up first under `/mnt/us/selfhost-catalog-backups/20260709-152118`.

Result:

1. The fake row appeared in the stock Library and was user-actionable.
2. Tapping it produced the stock UI error equivalent to "unable to start the selected application".
3. The useful KPP log line is `KSDKLibraryDownloadState: No download entry found`.
4. The tap also caused normal archive-sync/background transfer activity, but not a clean private-book download path.
5. The original `cc.db` was restored after the test and the fake row count returned to zero.

Conclusion: `cc.db` injection is enough for visibility/search experiments, but not enough for on-demand download. The stock Library expects an additional download-state/action contract before it will route a remote item into the content download manager. On this device, `/var/local/ksdk.asset.db` mostly mirrors local/downloaded assets and does not appear to be the authoritative archive list.

Next implementation direction:

1. Keep using `cc.db` rows only as the visible/searchable private-library index.
2. Add a Kindle-side private agent that maps synthetic CDE keys to self-hosted URLs.
3. Intercept the failed/private-row action path or provide a lightweight adjacent action, then download into `/mnt/us/documents`.
4. Trigger `scanner reScanFile` and `ccat triggerUpdate` so the fake archived row is replaced by a normal local row after download.

## Private Cloud Agent Smoke Test

Implementation: `privatecloud/server.py` and `privatecloud/kindle-agent.sh`.

Test action: started the host server on `http://192.168.1.75:8765`, copied the agent to `/mnt/us/privatecloud/kindle-agent.sh`, then ran `init`, `sync`, `list`, and `download` on the Kindle.

Observed result:

1. Kindle reached the host server successfully.
2. The agent downloaded the fixture to `/mnt/us/documents/PrivateCloud/`.
3. The Kindle created a normal `.sdr` sidecar for the file.
4. `cc.db` showed the downloaded file as `p_isArchived=0`, `p_isVisibleInHome=1`, with `p_location` under `/mnt/us/documents/PrivateCloud/`.

Conclusion: the self-hosted side-channel works for local delivery and stock Library ingestion. The next problem is only the pre-download cloud-like UX: making all private books visible/searchable as remote rows, then routing the tap/download action to the private agent.

## Remote-Only Private Row Tap Test

Capture: `observer/captures/action-20260709-154241-remote-only-private-row-tap`

Test action: deployed one private remote-only catalog row from the self-host manifest and tapped it in the stock Library.

Observed result:

1. The item appeared as a stock Library item.
2. Tapping it showed the stock fatal application dialog: "Impossibile avviare l'applicazione selezionata. Riprova."
3. Dismissing the dialog left the UI on a blank/white screen until services were restarted.
4. Logs show `pillowd` handled `appmgrAppFailedFatal`.
5. KPP logged repeated `KSDKLibraryDownloadState: No download entry found` at the same point.
6. The test catalog was restored from the clean backup and verified with zero `SELFHOST%` rows.

Conclusion: raw archived-row injection is the wrong final integration point for taps. It is useful for search/visibility research, but tapping such a row drives KPP into a fatal app-launch path unless the missing download-state/action contract is satisfied. The next implementation should avoid tapping synthetic rows directly and instead use either:

1. a separate private download action that downloads then lets the stock Library open the normal local row, or
2. a deeper KPP/KSDK hook that supplies the missing download-state entry before launch.

## Remote Row With KSDK Asset Node Test

Capture: `observer/captures/action-20260709-155316-remote-only-with-ksdk-row-tap`

Test action: deployed both a private `cc.db Entries` row and a matching `ksdk.asset.db Nodes` row shaped like an existing archived/document asset.

Observed result:

1. The item appeared in the stock Library.
2. Tapping it still produced the fatal application dialog and blank/white surface behavior.
3. Both `cc.db` and `ksdk.asset.db` were restored from `/mnt/us/selfhost-catalog-backups/20260709-155253`.
4. Verification returned zero private `SELFHOST%` rows in both databases.

Conclusion: the missing contract is not just the KSDK asset node. The tap path likely needs an internal action/intent/download-card state owned by KPP/CMM/download manager, not only catalog metadata. Stop testing raw tappable remote rows. Build the next version around the already-working agent download path.
