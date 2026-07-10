#!/bin/sh
set -eu

DIR="${1:?usage: observer/scripts/summarize-action.sh observer/captures/action-...}"

echo "== Unique external endpoints =="
awk '/^tcp/ && $5 !~ /192\.168\.1\.75|127\.0\.0\.1/ {print $7, $5, $6}' "$DIR/samples.txt" | sort -u

echo
echo "== Sync timeline =="
rg -n \
  "metric_name value sync|SyncAndCheck sync state|Manual sync event|Received sync my kindle|Init full sync|Init dataset sync|ProcessingToDo|start_transfer|header:list|end_transfer|DownloadArchiveItems|writeSyncDataToFile|post_status|UPLOAD_CRASHES" \
  "$DIR/log-tail.txt" | sed -n '1,180p' || true

echo
echo "== UI and local service transitions =="
rg -n \
  "appStateChange|Active KPP view|StartingToDo|tmdReady|webReader listening|KPP_HOME|ProfilesDataSyncManager" \
  "$DIR/log-tail.txt" | sed -n '1,120p' || true
