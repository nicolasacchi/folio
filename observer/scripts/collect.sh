#!/bin/sh
set -eu

KINDLE_HOST="${KINDLE_HOST:-root@192.168.1.95}"
KINDLE_SSH_OPTS="${KINDLE_SSH_OPTS:--F /dev/null}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-observer/captures/$STAMP}"

mkdir -p "$OUT_DIR"

ssh_kindle() {
  # shellcheck disable=SC2086
  ssh $KINDLE_SSH_OPTS -o BatchMode=yes "$KINDLE_HOST" "$@"
}

if ! ssh_kindle 'true' >/dev/null 2>&1; then
  echo "Cannot connect to $KINDLE_HOST. Check SSH access or run with network permission." >&2
  exit 1
fi

capture() {
  name="$1"
  shift
  echo "capturing $name"
  ssh_kindle "$@" > "$OUT_DIR/$name.txt" 2>&1 || true
}

capture version 'printf "date="; date; printf "hostname="; hostname; printf "uname="; uname -a; for f in /etc/prettyversion.txt /etc/version.txt /etc/issue; do [ -r "$f" ] && echo "--- $f" && cat "$f"; done'
capture mounts 'mount; echo; df -h'
capture processes 'ps -ef; echo; pstree -p 2>/dev/null || true'
capture init 'initctl list 2>/dev/null | sort'
capture sockets '(ss -tunp 2>/dev/null || netstat -tunp 2>/dev/null || netstat -anp 2>/dev/null || true); echo; cat /etc/resolv.conf /var/run/resolv.conf 2>/dev/null'
capture lipc_services 'lipc-probe -l 2>/dev/null | sort'
capture lipc_focus 'for s in com.lab126.KPPMainApp com.lab126.cloudcomm com.lab126.whisperstore com.amazon.kindlecontentdownloadmanager com.lab126.transferService com.lab126.amazonRegistrationService com.lab126.DeviceAuthenticationService com.lab126.KindleIdentity com.lab126.wifid com.acs.logmgr com.acs.minerva; do echo "### $s"; lipc-probe "$s" 2>&1 || true; done'
capture lipc_log_levels 'for s in com.acs.logmgr com.acs.minerva com.lab126.wifid; do echo "### $s"; lipc-get-prop "$s" logLevel 2>&1 || true; lipc-get-prop "$s" logMask 2>&1 || true; done'
capture log_inventory 'for d in /var/log /var/local/log /mnt/us/system /mnt/us/system/logbackup; do [ -d "$d" ] && echo "### $d" && ls -lat "$d" | sed -n "1,120p"; done'
capture kpp_files 'echo "### /app"; find /app -maxdepth 3 -type f 2>/dev/null | sort; echo "### /opt/amazon/ebook/config"; find /opt/amazon/ebook/config -maxdepth 2 -type f 2>/dev/null | sort; echo "### /opt/amazon/ebook/lib selected"; find /opt/amazon/ebook/lib -maxdepth 1 -type f 2>/dev/null | grep -Ei "sync|whisper|download|store|cloud|identity|auth|device|content|reader|purchase|merchant" | sort'
capture recent_messages 'tail -n 600 /var/log/messages 2>/dev/null || true'
capture recent_netlog 'tail -n 300 /var/log/netlog 2>/dev/null || true'

echo "$OUT_DIR"
