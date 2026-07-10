#!/bin/sh
set -eu

KINDLE_HOST="${KINDLE_HOST:-root@192.168.1.95}"
KINDLE_SSH_OPTS="${KINDLE_SSH_OPTS:--F /dev/null}"

# shellcheck disable=SC2086
exec ssh $KINDLE_SSH_OPTS -o BatchMode=yes "$KINDLE_HOST" '
echo "Watching /var/log/messages and /var/log/netlog. Press Ctrl-C to stop."
tail -f /var/log/messages /var/log/netlog 2>/dev/null
'
