#!/bin/sh
set -eu

PRIVATECLOUD_DIR=${PRIVATECLOUD_DIR:-/mnt/us/privatecloud}
DOCUMENT_DIR=${DOCUMENT_DIR:-/mnt/us/documents/PrivateCloud}
CONFIG_FILE="$PRIVATECLOUD_DIR/config"
MANIFEST_FILE="$PRIVATECLOUD_DIR/manifest.tsv"

SERVER_URL=${PRIVATECLOUD_SERVER_URL:-}
AUTH_TOKEN=${PRIVATECLOUD_AUTH_TOKEN:-}

# The config file lives on the USB-exposed /mnt/us partition, so it must never
# be sourced as shell code. Parse only the keys we expect and validate values.
load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            SERVER_URL)
                case "$value" in
                    http://*|https://*)
                        case "$value" in
                            *[!A-Za-z0-9:/?=._~%-]*)
                                echo "Ignoring SERVER_URL with unsafe characters in $CONFIG_FILE" >&2
                                ;;
                            *)
                                SERVER_URL=$value
                                ;;
                        esac
                        ;;
                    *)
                        echo "Ignoring SERVER_URL without http(s):// scheme in $CONFIG_FILE" >&2
                        ;;
                esac
                ;;
            AUTH_TOKEN)
                case "$value" in
                    ''|*[!A-Za-z0-9._~-]*)
                        echo "Ignoring invalid AUTH_TOKEN in $CONFIG_FILE" >&2
                        ;;
                    *)
                        AUTH_TOKEN=$value
                        ;;
                esac
                ;;
        esac
    done < "$CONFIG_FILE"
}

load_config

usage() {
    cat <<'EOF'
Usage:
  kindle-agent.sh init http://SERVER:8765 [TOKEN]
  kindle-agent.sh sync
  kindle-agent.sh list
  kindle-agent.sh download BOOK_ID
  kindle-agent.sh refresh FILE_PATH
EOF
}

require_server() {
    if [ -z "${SERVER_URL:-}" ]; then
        echo "SERVER_URL is not configured. Run: kindle-agent.sh init http://SERVER:8765" >&2
        exit 2
    fi
}

fetch() {
    fetch_url=$1
    fetch_output=$2
    if [ -n "${AUTH_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer $AUTH_TOKEN" "$fetch_url" -o "$fetch_output"
    else
        curl -fsSL "$fetch_url" -o "$fetch_output"
    fi
}

refresh_file() {
    path=$1
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.scanner reScanFile "$path" 2>/dev/null || true
        lipc-set-prop com.lab126.ccat triggerUpdate 1 2>/dev/null || true
    fi
}

sync_manifest() {
    require_server
    mkdir -p "$PRIVATECLOUD_DIR"
    tmp="$MANIFEST_FILE.tmp"
    fetch "$SERVER_URL/manifest.tsv" "$tmp"
    mv "$tmp" "$MANIFEST_FILE"
}

list_manifest() {
    if [ ! -f "$MANIFEST_FILE" ]; then
        sync_manifest
    fi
    awk -F '\t' 'NR > 1 { printf "%s  %s", $1, $2; if ($3 != "") printf " - %s", $3; printf " (%s bytes)\n", $4 }' "$MANIFEST_FILE"
}

download_book() {
    require_server
    id=$1
    if [ ! -f "$MANIFEST_FILE" ]; then
        sync_manifest
    fi

    title=$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$MANIFEST_FILE")
    sha256=$(awk -F '\t' -v id="$id" '$1 == id { print $5; exit }' "$MANIFEST_FILE")
    url_path=$(awk -F '\t' -v id="$id" '$1 == id { print $7; exit }' "$MANIFEST_FILE")
    filename=$(awk -F '\t' -v id="$id" '$1 == id { print $8; exit }' "$MANIFEST_FILE")
    if [ -z "$url_path" ]; then
        echo "Book id not found: $id" >&2
        exit 3
    fi

    # The manifest arrives over plain HTTP, so treat filename as hostile.
    case "$filename" in
        ''|.*|*/*)
            echo "Refusing unsafe filename from manifest: $filename" >&2
            exit 5
            ;;
    esac

    mkdir -p "$DOCUMENT_DIR"
    output="$DOCUMENT_DIR/$filename"
    tmp="$output.part"

    echo "Downloading $title ($id)"
    fetch "$SERVER_URL$url_path" "$tmp"
    actual=$(sha256sum "$tmp" | awk '{ print $1 }')
    if [ "$actual" != "$sha256" ]; then
        echo "Checksum mismatch for $filename" >&2
        echo "expected: $sha256" >&2
        echo "actual:   $actual" >&2
        exit 4
    fi

    mv "$tmp" "$output"
    refresh_file "$output"
    echo "$output"
}

cmd=${1:-}
case "$cmd" in
    init)
        url=${2:-}
        token=${3:-}
        if [ -z "$url" ]; then
            usage
            exit 2
        fi
        mkdir -p "$PRIVATECLOUD_DIR"
        printf "SERVER_URL=%s\n" "$url" > "$CONFIG_FILE"
        if [ -n "$token" ]; then
            printf "AUTH_TOKEN=%s\n" "$token" >> "$CONFIG_FILE"
        fi
        chmod 600 "$CONFIG_FILE"
        ;;
    sync)
        sync_manifest
        ;;
    list)
        list_manifest
        ;;
    download)
        if [ $# -ne 2 ]; then
            usage
            exit 2
        fi
        download_book "$2"
        ;;
    refresh)
        if [ $# -ne 2 ]; then
            usage
            exit 2
        fi
        refresh_file "$2"
        ;;
    *)
        usage
        exit 2
        ;;
esac
