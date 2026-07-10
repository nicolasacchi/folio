#!/bin/sh
# KUAL entry points for the kindled daemon. Shell stays deliberately thin:
# all real logic lives in the Rust binary.
set -eu

PRIVATECLOUD_DIR=${PRIVATECLOUD_DIR:-/mnt/us/privatecloud}
KINDLED="$PRIVATECLOUD_DIR/kindled"
PIDFILE="$PRIVATECLOUD_DIR/kindled.pid"
LOG="$PRIVATECLOUD_DIR/kindled.log"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

daemon_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-}" in
    sync)
        log "manual sync"
        "$KINDLED" sync >> "$LOG" 2>&1 || log "sync exited with errors"
        ;;
    start)
        if daemon_running; then
            log "daemon already running (pid $(cat "$PIDFILE"))"
        else
            "$KINDLED" daemon >> "$LOG" 2>&1 &
            echo $! > "$PIDFILE"
            log "daemon started (pid $(cat "$PIDFILE"))"
        fi
        ;;
    stop)
        if daemon_running; then
            kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
            log "daemon stopped"
        else
            rm -f "$PIDFILE"
            log "daemon was not running"
        fi
        ;;
    refresh)
        lipc-set-prop com.lab126.scanner doFullScan 1 2>/dev/null || true
        lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
        log "library refresh requested"
        ;;
    *)
        log "unknown command: ${1:-}"
        exit 2
        ;;
esac
