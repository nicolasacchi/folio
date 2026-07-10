#!/bin/sh
set -eu

DIR="${1:?usage: observer/scripts/summarize-local-add.sh observer/captures/action-...}"
LOG="$DIR/log-tail.txt"

echo "== Local add / scanner timeline =="
rg -n \
  "scan\\[|libload|CONTENT_NOT_CLOUD_INDEXABLE|allowed to index|INDEX_TITLE|com\\.lab126\\.ccat|PlatformDatabaseListener|OnAssetsUpdated|ConversionTaskManager|LibraryBookDataProvider|TitleIndexer|\\.sdr|reScanFile|doFullScan|triggerUpdate" \
  "$LOG" | sed -n '1,180p' || true

echo
echo "== Network activity during local add =="
awk '/^tcp/ && $5 !~ /192\.168\.1\.75|127\.0\.0\.1/ {print $7, $5, $6}' "$DIR/samples.txt" | sort -u
