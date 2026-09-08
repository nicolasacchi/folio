#!/bin/sh
set -eu

KINDLE_HOST=${KINDLE_HOST:-root@kindle}
BACKUP_DIR=${1:-}

if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR=$(ssh -F /dev/null "$KINDLE_HOST" 'cat /mnt/us/privatecloud/last-ksdk-catalog-test-backup 2>/dev/null || true')
fi

if [ -z "$BACKUP_DIR" ]; then
    echo "No backup directory supplied and no last backup marker found." >&2
    exit 2
fi

# BACKUP_DIR may come from a marker file on /mnt/us, which any PC the Kindle
# is plugged into can write. It is interpolated into a remote root shell, so
# only accept the expected backup layout with a safe character set.
case "$BACKUP_DIR" in
    ''|*..*|*[!A-Za-z0-9._/-]*)
        echo "Unsafe BACKUP_DIR: $BACKUP_DIR" >&2
        exit 2
        ;;
    /mnt/us/selfhost-catalog-backups/*)
        ;;
    *)
        echo "BACKUP_DIR must be under /mnt/us/selfhost-catalog-backups/: $BACKUP_DIR" >&2
        exit 2
        ;;
esac

ssh -F /dev/null "$KINDLE_HOST" "set -e
test -f '$BACKUP_DIR/cc.before-private.db'
test -f '$BACKUP_DIR/ksdk.asset.before-private.db'
stop kppmainapp 2>/dev/null || true
stop kfxreader 2>/dev/null || true
stop kfxview 2>/dev/null || true
stop scanner 2>/dev/null || true
stop framework 2>/dev/null || true
stop archive 2>/dev/null || true
sleep 2
cat '$BACKUP_DIR/cc.before-private.db' > /var/local/cc.db
cat '$BACKUP_DIR/ksdk.asset.before-private.db' > /var/local/ksdk.asset.db
chown framework:javauser /var/local/cc.db /var/local/ksdk.asset.db 2>/dev/null || true
chmod 775 /var/local/cc.db /var/local/ksdk.asset.db 2>/dev/null || true
sync
start archive 2>/dev/null || true
start framework 2>/dev/null || true
start scanner 2>/dev/null || true
start kppmainapp 2>/dev/null || true
lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
"

echo "Restored cc.db and ksdk.asset.db from $BACKUP_DIR"
