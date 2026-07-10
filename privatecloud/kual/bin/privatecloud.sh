#!/bin/sh
set -eu

PRIVATECLOUD_DIR=${PRIVATECLOUD_DIR:-/mnt/us/privatecloud}
DOCUMENT_DIR=${DOCUMENT_DIR:-/mnt/us/documents/PrivateCloud}
AGENT="$PRIVATECLOUD_DIR/kindle-agent.sh"
MANIFEST="$PRIVATECLOUD_DIR/manifest.tsv"
LOG="$PRIVATECLOUD_DIR/kual.log"
LIST_DOC="$DOCUMENT_DIR/PrivateCloud Library.txt"

log() {
    mkdir -p "$PRIVATECLOUD_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

refresh_library() {
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.scanner doFullScan 1 2>/dev/null || true
        lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
    fi
}

require_agent() {
    if [ ! -x "$AGENT" ]; then
        log "agent missing or not executable: $AGENT"
        exit 2
    fi
}

sync_manifest() {
    require_agent
    sh "$AGENT" sync >> "$LOG" 2>&1
}

write_list() {
    require_agent
    sync_manifest
    mkdir -p "$DOCUMENT_DIR"
    {
        echo "PrivateCloud Library"
        echo
        awk -F '\t' 'NR > 1 {
            printf "%s", $2
            if ($3 != "") printf " - %s", $3
            printf " [%s]\n", $1
        }' "$MANIFEST"
    } > "$LIST_DOC"
    lipc-set-prop com.lab126.scanner reScanFile "$LIST_DOC" 2>/dev/null || true
    lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
    log "wrote list document: $LIST_DOC"
}

download_next() {
    require_agent
    sync_manifest
    mkdir -p "$DOCUMENT_DIR"

    awk -F '\t' 'NR > 1 { print $1 "\t" $8 }' "$MANIFEST" | while IFS='	' read -r id filename; do
        [ -n "$id" ] || continue
        [ -n "$filename" ] || continue
        if [ ! -e "$DOCUMENT_DIR/$filename" ]; then
            log "download-next selected $id $filename"
            sh "$AGENT" download "$id" >> "$LOG" 2>&1
            refresh_library
            exit 0
        fi
    done

    log "download-next found no undownloaded items"
}

case "${1:-}" in
    sync)
        log "sync start"
        sync_manifest
        log "sync done"
        ;;
    download-next)
        download_next
        ;;
    write-list)
        write_list
        ;;
    refresh)
        refresh_library
        log "refresh requested"
        ;;
    *)
        log "unknown command: ${1:-}"
        exit 2
        ;;
esac
