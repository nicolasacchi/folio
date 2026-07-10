#!/bin/sh
set -eu

DIR="${1:?usage: observer/scripts/summarize-download.sh observer/captures/action-...}"
LOG="$DIR/log-tail.txt"
SAMPLES="$DIR/samples.txt"

redact() {
  sed -E \
    -e 's#Downloads/Items01/[^ ]+#Downloads/Items01/<staged-file>#g' \
    -e 's#DownloadState\[[^]|]+\|#DownloadState[<content-id>|#g' \
    -e 's#cdekey\" : \"[^\"]+\"#cdekey\" : \"<content-id>\"#g' \
    -e 's#AssetID [^ ]+#AssetID <asset-id>#g' \
    -e 's#asset: [^ ]+#asset: <asset-id>#g'
}

echo "== Unique external endpoints =="
awk '/^tcp/ && $5 !~ /192\.168\.1\.75|127\.0\.0\.1/ {print $7, $5, $6}' "$SAMPLES" | sort -u

echo
echo "== Download control flow =="
rg -n \
  "DownloadBookAction|KSDKLibraryDownloadState:INFO.*Publish Download Progress|ManifestDownloadPostProcessor|AbstractManifestAction|TransportAdaptor:INFO.*nontododownload|ContentDownloadManager:INFO.*Starting DownloadContent|ContentDownloadWorker:INFO.*enqueue download|TMD download request|AssetDownloadComplete|AssetDownload : STATUS_DEFERRED|ContentReplacer:INFO|PostDownloadCCUpdater updated successfully|CatalogTransactionImpl:CommitResult|TitleIndexer:Information|ReaderSDKImpl:Information::Opened Book" \
  "$LOG" | redact | sed -n '1,220p' || true

echo
echo "== Transfer summary =="
rg -n \
  "start_transfer:starting|header:list|end_transfer:(COMPLETED|FAILED|DEFERRED)" \
  "$LOG" | redact | sed -n '1,180p' || true
