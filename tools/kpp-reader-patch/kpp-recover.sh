#!/bin/sh
# Restore the stock Reader-utils.jar after a kpp-apply.sh patch, from ANY
# shell on the device (USB console, diagnostic mode, whatever you have) —
# does not depend on the reader framework, WiFi, or the reverse SSH tunnel
# being up. Written for the 2026-07-13 lockout incident: the auto-heal job
# installed by kpp-apply.sh didn't fire because it was hooked too late in
# boot, so the device had to be recovered by hand over a USB console.
#
# Safe to run even if nothing was ever patched — it's a no-op unless one of
# the known backup locations exists.
#
# Usage: sh kpp-recover.sh

set -e
J=/opt/amazon/ebook/lib/Reader-utils.jar
CANDIDATES="/var/local/kpp-Reader-utils.jar.orig"
for d in /mnt/us/privatecloud/kpp-backup-*; do
    [ -f "$d/Reader-utils.jar.orig" ] && CANDIDATES="$CANDIDATES $d/Reader-utils.jar.orig"
done

ORIG=""
for c in $CANDIDATES; do
    if [ -f "$c" ]; then
        ORIG="$c"
        break
    fi
done

if [ -z "$ORIG" ]; then
    echo "No backup jar found (checked: $CANDIDATES). Nothing to restore."
    exit 0
fi

echo "Restoring from: $ORIG"
echo "  backup md5:    $(md5sum "$ORIG")"
echo "  current md5:   $(md5sum "$J" 2>/dev/null || echo 'MISSING')"

mount -o remount,rw /
cp "$ORIG" "$J.recovering"
mv "$J.recovering" "$J"
rm -f /etc/upstart/kpp-autoheal.conf /var/local/kpp-patch-armed /var/local/kpp-patch-firstboot
sync
mount -o remount,ro / 2>/dev/null || echo "WARN: remount ro failed (harmless)"

echo "  restored md5:  $(md5sum "$J")"
echo "Done. Reboot for it to take effect: reboot"
