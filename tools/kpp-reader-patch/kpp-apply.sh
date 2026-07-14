#!/bin/sh
# Apply the KPP reader bytecode patch + arm the dead-man auto-heal.
#
# READ tools/kpp-reader-patch/README.md FIRST. This patch caused a boot
# lockout on 2026-07-13 because the auto-heal job it installed was hooked at
# too late a boot stage. kpp-autoheal.conf in this directory has been fixed
# to hook earlier (`start on startup`) but that fix is UNVERIFIED on real
# hardware (the device was locked out before it could be tested). Do not run
# this against a device you can't afford to lose remote access to until
# you've confirmed the corrected autoheal actually fires before the reader
# framework on a healthy boot.
#
# Usage (run ON the Kindle, as root):
#   scp patch_reader_utils.py kpp-autoheal.conf kpp-apply.sh root@kindle:/mnt/us/privatecloud/
#   ssh root@kindle
#   cd /mnt/us/privatecloud
#   cp /opt/amazon/ebook/lib/Reader-utils.jar staging.jar
#   mkdir -p staging && (cd staging && unzip -q ../staging.jar com/amazon/ebook/booklet/reader/utils/ReaderUtils.class)
#   python3 patch_reader_utils.py staging/com/amazon/ebook/booklet/reader/utils/ReaderUtils.class
#   (cd staging && zip -q ../staging.jar com/amazon/ebook/booklet/reader/utils/ReaderUtils.class)
#   sh kpp-apply.sh staging.jar
set -e

PATCHED_JAR="${1:?usage: kpp-apply.sh <path-to-patched-jar>}"
J=/opt/amazon/ebook/lib/Reader-utils.jar
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo "unknown")
BK="/mnt/us/privatecloud/kpp-backup-$TS"

[ -f "$PATCHED_JAR" ] || { echo "ERROR: patched jar not found: $PATCHED_JAR"; exit 1; }
[ -f "/mnt/us/privatecloud/kpp-autoheal.conf" ] || { echo "ERROR: kpp-autoheal.conf not staged at /mnt/us/privatecloud/"; exit 1; }

mkdir -p "$BK"
cp -p "$J" /var/local/kpp-Reader-utils.jar.orig || { echo "ERROR: backup to /var/local failed"; exit 1; }
cp -p "$J" "$BK/Reader-utils.jar.orig" || { echo "ERROR: backup to $BK failed"; exit 1; }
rm -f /var/local/kpp-patch-firstboot

mount -o remount,rw / || { echo "ERROR: remount rw failed"; exit 1; }
if cp "$PATCHED_JAR" "$J.new" && mv "$J.new" "$J"; then
    :
else
    echo "ERROR: jar replace failed; restoring stock"
    cp /var/local/kpp-Reader-utils.jar.orig "$J"
    mount -o remount,ro / 2>/dev/null || true
    exit 1
fi
cp /mnt/us/privatecloud/kpp-autoheal.conf /etc/upstart/kpp-autoheal.conf || echo "WARN: autoheal install failed"
sync
mount -o remount,ro / 2>/dev/null || echo "WARN: remount ro failed (harmless; next boot is ro anyway)"
touch /var/local/kpp-patch-armed

echo "=== APPLIED + ARMED ==="
echo "jar:       $(md5sum "$J")"
echo "autoheal:  $([ -f /etc/upstart/kpp-autoheal.conf ] && echo installed || echo MISSING)"
echo "armed:     $([ -f /var/local/kpp-patch-armed ] && echo yes || echo NO)"
echo "backup:    /var/local/kpp-Reader-utils.jar.orig (+ $BK)"
echo
echo "Reboot now. If the reader is healthy and buttons work: rm -f /var/local/kpp-patch-armed to confirm/keep."
echo "If it breaks: reboot again -> auto-heal should restore stock before the reader starts."
echo "If auto-heal doesn't fire (as happened 2026-07-13): use kpp-recover.sh from any available shell (USB console etc)."
