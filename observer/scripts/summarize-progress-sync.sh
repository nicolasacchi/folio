#!/bin/sh
set -eu

DIR="${1:?usage: observer/scripts/summarize-progress-sync.sh observer/captures/action-...}"
LOG="$DIR/log-tail.txt"
SAMPLES="$DIR/samples.txt"

redact() {
  sed -E \
    -e 's#Downloads/Items01/[^ ,\"}]+#Downloads/Items01/<book-file>#g' \
    -e 's#app://com.lab126.booklet.reader/[^\",}]+#app://com.lab126.booklet.reader/<book-uri>#g' \
    -e 's#UUID\\\":\\\"[^\"]+\\\"#UUID\\\":\\\"<uuid>\\\"#g' \
    -e 's#uuid: [0-9a-f-]+#uuid: <uuid>#g' \
    -e 's#cde_key value [A-Z0-9!_-]+#cde_key value <content-id>#g' \
    -e 's#\"cde_key\" : \"[^\"]+\"#\"cde_key\" : \"<content-id>\"#g' \
    -e 's#cde_key\" : \"[^\"]+\"#cde_key\" : \"<content-id>\"#g' \
    -e 's#OC[0-9A-Z!_-]{10,}#<content-id>#g' \
    -e 's#[A-Z0-9!_-]{24,}#<content-id>#g' \
    -e 's#ASIN: [A-Z0-9!_-]+#ASIN: <content-id>#g' \
    -e 's#Asin:[^;]+;#Asin:<content-id>;#g' \
    -e 's#Title:[^,;]+#Title:<private>#g' \
    -e 's#metric_session_id\" : \"[^\"]+\"#metric_session_id\" : \"<session-id>\"#g' \
    -e 's#request id: \\[[^]]+\\]#request id: [<request-id>]#g' \
    -e 's#requestId \\[[^]]+\\]#requestId [<request-id>]#g' \
    -e 's#start=[0-9]+, end=[0-9]+#start=<pos>, end=<pos>#g' \
    -e 's#start_position value [0-9]+#start_position value <pos>#g' \
    -e 's#end_position value [0-9]+#end_position value <pos>#g'
}

echo "== Reader / progress timeline =="
rg -n \
  "open_book|booklet.reader|ReaderSDKImpl:Information::Opened Book|ReadingProgressPlugin|Saving reading progress annotation|saveReadingProgress|AnnotationController|AnnotationCache|WhisperStore|ReadingTimerController|CloseBook|LPR|last read|position range|ereader_book_consume_content|start_position|end_position" \
  "$LOG" | redact | sed -n '1,220p' || true

echo
echo "== Sync / upload timeline =="
rg -n \
  "metric_name value sync|SyncAndCheck sync state|Manual sync event|WhisperSyncV2PaginateServiceImpl|ProcessingToDo|ProcessingToDoItem|legacy\\.UPLOAD|whispersync\\.upload|post_status|start_transfer|header:list|end_transfer" \
  "$LOG" | redact | sed -n '1,220p' || true

echo
echo "== Unique external endpoints =="
awk '/^tcp/ && $5 !~ /127\.0\.0\.1/ {print $7, $5, $6}' "$SAMPLES" | sort -u
