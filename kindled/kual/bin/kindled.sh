#!/bin/sh
# KUAL entry points for the kindled daemon. Shell stays deliberately thin:
# all real logic lives in the Rust binary.
#
# When the upstart job is installed (/etc/upstart/kindled.conf, see
# ../upstart/kindled.conf) start/stop delegate to it — upstart would
# otherwise respawn a daemon KUAL had stopped, and two supervisors would
# fight over one pid.
set -eu

PRIVATECLOUD_DIR=${PRIVATECLOUD_DIR:-/mnt/us/privatecloud}
KINDLED="$PRIVATECLOUD_DIR/kindled"
PIDFILE="$PRIVATECLOUD_DIR/kindled.pid"
LOG="$PRIVATECLOUD_DIR/kindled.log"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

upstart_managed() {
    [ -f /etc/upstart/kindled.conf ] && command -v initctl >/dev/null 2>&1
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
        if upstart_managed; then
            start kindled >/dev/null 2>&1 || true
            log "daemon start requested via upstart"
        elif daemon_running; then
            log "daemon already running (pid $(cat "$PIDFILE"))"
        else
            "$KINDLED" daemon >> "$LOG" 2>&1 &
            echo $! > "$PIDFILE"
            log "daemon started (pid $(cat "$PIDFILE"))"
        fi
        ;;
    stop)
        if upstart_managed; then
            stop kindled >/dev/null 2>&1 || true
            log "daemon stop requested via upstart"
        elif daemon_running; then
            kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
            log "daemon stopped"
        else
            rm -f "$PIDFILE"
            log "daemon was not running"
        fi
        ;;
    refresh)
        lipc-set-prop com.lab126.scanner doFullScan 1 2>/dev/null || true
        lipc-set-prop com.lab126.scanner triggerUpdate 1 2>/dev/null || true
        lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
        log "library refresh requested"
        ;;
    *)
        log "unknown command: ${1:-}"
        exit 2
        ;;
esac
