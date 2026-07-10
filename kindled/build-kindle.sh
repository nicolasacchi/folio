#!/bin/sh
# Cross-compiles kindled for the Kindle (ARMv7, static musl).
# Requires rustup: rustup target add armv7-unknown-linux-musleabihf
set -eu

cd "$(dirname "$0")"
TARGET=armv7-unknown-linux-musleabihf

rustup target list --installed | grep -q "$TARGET" || rustup target add "$TARGET"
cargo build --release --target "$TARGET"

BIN="target/$TARGET/release/kindled"
echo
echo "built: $BIN ($(du -h "$BIN" | cut -f1))"
echo "install: scp $BIN root@KINDLE_IP:/mnt/us/privatecloud/kindled"
