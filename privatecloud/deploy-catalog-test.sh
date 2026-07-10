#!/bin/sh
set -eu

KINDLE_HOST=${KINDLE_HOST:-root@192.168.1.95}
SERVER_URL=${PRIVATECLOUD_SERVER_URL:-http://192.168.1.75:8765}
STAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR=${WORKDIR:-privatecloud/tmp/catalog-$STAMP}
BACKUP_DIR="/mnt/us/selfhost-catalog-backups/$STAMP"

mkdir -p "$WORKDIR"

if [ "${CONFIRM_REMOTE_ROW_TEST:-0}" != "1" ]; then
    echo "Refusing to deploy raw private remote rows without CONFIRM_REMOTE_ROW_TEST=1." >&2
    echo "These rows are useful for search/visibility research but tapping them can trigger a fatal Kindle app dialog." >&2
    exit 4
fi

EXISTING=$(ssh -F /dev/null "$KINDLE_HOST" 'sqlite3 /var/local/cc.db "select count(*) from Entries where p_cdeKey like \"SELFHOST%\";"')
if [ "$EXISTING" != "0" ] && [ "${ALLOW_EXISTING_PRIVATE_ROWS:-0}" != "1" ]; then
    echo "Refusing to deploy: current Kindle catalog already has $EXISTING SELFHOST row(s)." >&2
    echo "Run privatecloud/restore-catalog-test.sh with the clean backup first, or set ALLOW_EXISTING_PRIVATE_ROWS=1." >&2
    exit 3
fi

echo "Fetching manifest from $SERVER_URL"
curl -fsS "$SERVER_URL/manifest.tsv" -o "$WORKDIR/manifest.tsv"

echo "Pulling current cc.db"
scp -F /dev/null "$KINDLE_HOST:/var/local/cc.db" "$WORKDIR/cc.source.db"

echo "Building modified catalog copy"
python3 privatecloud/catalog_import.py \
    --db "$WORKDIR/cc.source.db" \
    --manifest "$WORKDIR/manifest.tsv" \
    --output "$WORKDIR/cc.private.db"

echo "Pushing modified catalog and installing with backup $BACKUP_DIR"
ssh -F /dev/null "$KINDLE_HOST" "mkdir -p '$BACKUP_DIR'"
scp -F /dev/null "$WORKDIR/cc.private.db" "$KINDLE_HOST:$BACKUP_DIR/cc.private.db"
ssh -F /dev/null "$KINDLE_HOST" "set -e
cp /var/local/cc.db '$BACKUP_DIR/cc.before-private.db'
stop kppmainapp 2>/dev/null || true
stop scanner 2>/dev/null || true
stop framework 2>/dev/null || true
stop archive 2>/dev/null || true
sleep 2
cat '$BACKUP_DIR/cc.private.db' > /var/local/cc.db
chown framework:javauser /var/local/cc.db 2>/dev/null || true
chmod 775 /var/local/cc.db 2>/dev/null || true
sync
start archive 2>/dev/null || true
start framework 2>/dev/null || true
start scanner 2>/dev/null || true
start kppmainapp 2>/dev/null || true
lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
echo '$BACKUP_DIR' > /mnt/us/privatecloud/last-catalog-test-backup
"

echo "Installed private catalog test rows."
echo "Backup: $BACKUP_DIR"
