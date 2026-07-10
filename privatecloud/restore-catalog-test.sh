#!/bin/sh
set -eu

KINDLE_HOST=${KINDLE_HOST:-root@192.168.1.95}
BACKUP_DIR=${1:-}

if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR=$(ssh -F /dev/null "$KINDLE_HOST" 'cat /mnt/us/privatecloud/last-catalog-test-backup 2>/dev/null || true')
fi

if [ -z "$BACKUP_DIR" ]; then
    echo "No backup directory supplied and no last backup marker found." >&2
    exit 2
fi

ssh -F /dev/null "$KINDLE_HOST" "set -e
test -f '$BACKUP_DIR/cc.before-private.db'
stop kppmainapp 2>/dev/null || true
stop scanner 2>/dev/null || true
stop framework 2>/dev/null || true
stop archive 2>/dev/null || true
sleep 2
cat '$BACKUP_DIR/cc.before-private.db' > /var/local/cc.db
chown framework:javauser /var/local/cc.db 2>/dev/null || true
chmod 775 /var/local/cc.db 2>/dev/null || true
sync
start archive 2>/dev/null || true
start framework 2>/dev/null || true
start scanner 2>/dev/null || true
start kppmainapp 2>/dev/null || true
lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
"

echo "Restored catalog from $BACKUP_DIR"
