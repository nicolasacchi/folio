#!/bin/sh
set -eu

KINDLE_HOST="${KINDLE_HOST:-root@192.168.1.95}"
KINDLE_SSH_OPTS="${KINDLE_SSH_OPTS:--F /dev/null}"
LABEL="${1:-manual-action}"
DURATION="${2:-90}"
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9_.-' '_')"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-observer/captures/action-$STAMP-$SAFE_LABEL}"

mkdir -p "$OUT_DIR"

ssh_kindle() {
  # shellcheck disable=SC2086
  ssh $KINDLE_SSH_OPTS -o BatchMode=yes "$KINDLE_HOST" "$@"
}

if ! ssh_kindle 'true' >/dev/null 2>&1; then
  echo "Cannot connect to $KINDLE_HOST. Check SSH access or run with network permission." >&2
  exit 1
fi

ssh_kindle "logger -t codex-observer 'BEGIN $SAFE_LABEL $STAMP'; date; (ss -tunp 2>/dev/null || netstat -tunp 2>/dev/null || true)" > "$OUT_DIR/before.txt" 2>&1 || true

echo "Capturing $SAFE_LABEL for ${DURATION}s into $OUT_DIR"
echo "Perform the Kindle action now."

# shellcheck disable=SC2086
timeout "$DURATION" ssh $KINDLE_SSH_OPTS -o BatchMode=yes "$KINDLE_HOST" \
  'tail -n 0 -f /var/log/messages /var/log/netlog 2>/dev/null' \
  > "$OUT_DIR/log-tail.txt" 2>&1 &
tail_pid=$!

# shellcheck disable=SC2086
ssh $KINDLE_SSH_OPTS -o BatchMode=yes "$KINDLE_HOST" "
i=0
while [ \$i -lt $DURATION ]; do
  echo '---'
  date
  ps -ef | grep -Ei 'KPPMainApp|whisper|ContentDownload|cloud|sync|minerva|acs|store' | grep -v grep
  (ss -tunp 2>/dev/null || netstat -tunp 2>/dev/null || true)
  sleep 2
  i=\$((i + 2))
done
" > "$OUT_DIR/samples.txt" 2>&1 || true

wait "$tail_pid" 2>/dev/null || true

ssh_kindle "logger -t codex-observer 'END $SAFE_LABEL $STAMP'; date; (ss -tunp 2>/dev/null || netstat -tunp 2>/dev/null || true)" > "$OUT_DIR/after.txt" 2>&1 || true

echo "$OUT_DIR"
